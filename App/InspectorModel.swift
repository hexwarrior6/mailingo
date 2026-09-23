import AppKit
import EmailCore
import Foundation
import MailIntegration
import SwiftUI
import TranslationCore

/// 邮件解析看板的状态与加载逻辑。
@MainActor
final class InspectorModel: ObservableObject {

    enum EngineChoice: String, CaseIterable, Identifiable {
        case apple
        case marker
        case identity

        var id: String { rawValue }

        var label: String {
            switch self {
            case .apple: "Apple 翻译"
            case .marker: "标记替换"
            case .identity: "原样返回"
            }
        }

        var engine: TranslationEngine {
            switch self {
            case .apple: AppleTranslationEngine()
            case .marker: MarkerTranslationEngine()
            case .identity: IdentityTranslationEngine()
            }
        }
    }

    /// 当前引擎是不是"看不到上下文"，因而孤立片段会被跳过、保留原文。
    var skipsContextlessOrphans: Bool { !effectiveEngine.hasFullContext }

    /// 当前显示的到底是不是真译文。
    ///
    /// 开发者模式关闭时引擎被强制成 Apple 翻译，所以恒为 true；
    /// 界面上用它决定右侧标题写「中文译文」还是「切片后」。
    var isShowingRealTranslation: Bool {
        !DeveloperMode.isOn || engineChoice == .apple
    }

    enum LoadState {
        case idle
        case loading
        case failed(String)
        case loaded
    }

    /// 「跟随 Mail 自动切换」的状态。
    enum MailFollowStatus: Equatable {
        case off
        /// 正在跟随，一切正常
        case following
        /// 瞬时状态：Mail 没开、没有阅读窗口、或选中的邮件还没同步过来
        case waiting(String)
        /// 需要用户在系统设置里授权「自动化」
        case permissionDenied
        case failed(String)
    }

    enum TranslationStatus: Equatable {
        case idle
        case running(done: Int, total: Int)
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var inspection: EmailInspection?
    @Published private(set) var translationStatus: TranslationStatus = .idle
    @Published private(set) var mailFollowStatus: MailFollowStatus = .off

    /// 是否跟随 Mail 的选中项自动切换。持久化 —— 这是个长期偏好。
    @Published var followsMailSelection: Bool =
        UserDefaults.standard.bool(forKey: InspectorModel.followsMailSelectionKey) {
        didSet {
            UserDefaults.standard.set(followsMailSelection, forKey: Self.followsMailSelectionKey)
            guard oldValue != followsMailSelection else { return }
            if followsMailSelection {
                lastMailSelectionID = nil
                followSuppressed = false
                pollMailSelection()
            } else {
                mailFollowStatus = .off
            }
        }
    }

    static let followsMailSelectionKey = "inspector.followsMailSelection"

    /// 已捕获的邮件（会话里来回好几封都会在这里，最新在前）。
    @Published private(set) var capturedMessages: [StoredMessage] = []
    /// 当前正在看的是哪一封。
    @Published private(set) var currentMessage: StoredMessage?

    @Published var engineChoice: EngineChoice = .apple {
        didSet {
            guard oldValue != engineChoice else { return }
            restartTranslation()
        }
    }

    private(set) var sourceBytes: Int = 0

    private var analysis: EmailAnalysis?
    private var translationTask: Task<Void, Never>?
    /// 每次翻译运行发一个令牌。取消不一定能立刻终止正在 await 的调用，
    /// 所以结果回来时要确认"我还是当前那一次"，否则旧邮件的译文会覆盖新邮件。
    private var runToken = UUID()

    /// 上一次处理过的请求 nonce，用来判断有没有新请求。
    private var lastHandledRequestNonce: String?
    /// 当前显示这封的 Message-ID。
    ///
    /// 用它来判断"同一封邮件是不是来了更完整的版本" ——
    /// Mail 对同一封会回调两次（先空壳、后完整），我们需要悄悄换上完整那份，
    /// 否则内嵌图片会一直是空白。
    private var currentInternetMessageID: String?
    /// 上一次从 Mail 读到的选中项，用来判断"选择变了没有"。
    private var lastMailSelectionID: String?
    /// 用户手动选过邮件之后，先别让自动跟随把他拉回去 ——
    /// 直到 Mail 那边的选中项真的变了，才恢复跟随。
    private var followSuppressed = false
    /// messages 目录的上次修改时间，避免每次轮询都全量重读元数据。
    private var lastMessagesDirectoryStamp: Date?

    // MARK: - 启动

    func bootstrap() async {
        refreshCapturedMessages(force: true)
        await loadMostRecent()
        // 启动时自检一次，但**不触发系统下载弹窗** ——
        // 只是把「语言包装了没」这类事实记下来，用户没要求就别打扰他。
        await runDiagnostics(allowDownloadTrigger: false)
    }

    // MARK: - 载入

    /// 载入最近捕获的那封。
    func loadMostRecent() async {
        refreshCapturedMessages(force: true)
        if let newest = capturedMessages.first {
            await load(messageID: newest.id)
        } else {
            state = .failed("""
            还没有捕获到任何邮件。

            请在 Mail 里打开一封邮件，点邮件顶部的「翻译」横幅 ——
            Mail 会把那封邮件交给 Mailingo 的扩展，扩展存好之后这里就能看到。
            """)
        }
    }

    /// 载入指定 ID 的邮件。
    ///
    /// - Parameter manual: 是不是用户手动选的（下拉里点、点横幅、拖文件）。
    ///   手动选过之后要**先别让自动跟随把人拉回去** ——
    ///   否则你刚点开另一封，下一秒就被 Mail 的选中项拽回来。
    func load(messageID: String, manual: Bool = true) async {
        if manual { followSuppressed = true }

        let stored = capturedMessages.first { $0.id == messageID }
            ?? MessageStore.all().first { $0.id == messageID }

        guard let stored else {
            state = .failed("找不到邮件 \(messageID)，可能已经被清理掉了。")
            return
        }
        guard let raw = MessageStore.rawMessage(id: messageID) else {
            state = .failed("邮件 \(messageID) 的原始内容读不出来。")
            return
        }

        currentMessage = stored
        currentInternetMessageID = stored.internetMessageID
        do {
            try await analyze(data: raw)
        } catch {
            state = .failed("解析失败：\(error.localizedDescription)")
        }
    }

    /// 用户从「打开 .eml…」选的文件。
    func load(fileURL: URL) async {
        currentMessage = nil
        currentInternetMessageID = nil
        do {
            try await analyze(data: Data(contentsOf: fileURL))
        } catch {
            state = .failed("读取失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 从 Mail 来的请求

    /// 处理 `mailingo://translate?id=xxx`。
    func handle(url: URL) {
        guard url.scheme == "mailingo",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else { return }

        // 立刻记下 nonce，避免随后的轮询把同一个请求再处理一遍
        markCurrentRequestHandled()
        Task { await load(messageID: id) }
    }

    // MARK: - 跟随 Mail 的选中项

    /// 查询 Mail 当前选中的是哪一封，需要的话切过去。
    ///
    /// 用 AppleScript 主动查，而不是靠被动信号：实测被动解码事件里
    /// 59 个相邻间隔有 38 个小于 1.5 秒（滚动列表/预取/打开会话时的批量解码），
    /// 跟"用户打开了哪一封"无关。
    func pollMailSelection() {
        guard followsMailSelection else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let selection = try await MailSelectionMonitor.shared.currentSelection()

                // Mail 的选中项变了 → 解除之前的手动抑制
                if selection.internetMessageID != self.lastMailSelectionID {
                    self.lastMailSelectionID = selection.internetMessageID
                    self.followSuppressed = false
                }

                guard !self.followSuppressed else {
                    self.mailFollowStatus = .following
                    return
                }

                guard let message = MessageStore.message(
                    matchingInternetMessageID: selection.internetMessageID
                ) else {
                    // Mail 选中了，但那封邮件扩展还没收到（刚点开、还在解码）
                    self.mailFollowStatus = .waiting("Mail 选中的邮件还没同步过来…")
                    return
                }

                self.mailFollowStatus = .following
                guard message.id != self.currentMessage?.id else { return }
                await self.load(messageID: message.id, manual: false)
            } catch let error as MailSelectionError {
                switch error {
                case .automationDenied:
                    self.mailFollowStatus = .permissionDenied
                default:
                    self.mailFollowStatus = error.isTransient ? .waiting(error.description) : .failed(error.description)
                }
            } catch {
                self.mailFollowStatus = .failed(String(describing: error))
            }
        }
    }

    /// 打开「系统设置 → 隐私与安全性 → 自动化」，引导用户授权。
    func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// 轮询 Mail 那边的动静。做两件事：
    ///
    /// 1. **待处理请求** —— 为什么除了 URL scheme 还要轮询：容器 App 可能已经在
    ///    运行，这时 LaunchServices 打开 URL 未必能把请求送进来；而且 appex 是
    ///    沙盒进程，打开 URL 有失败的可能。读一个请求文件是兜底。
    ///
    /// 2. **更完整的版本** —— Mail 对同一封邮件会回调两次：先给"附件还没下载"
    ///    的空壳（内嵌图片是空的），再给完整版。如果当前显示的是空壳，
    ///    这里要悄悄换上完整那份，否则图片一直是空白。
    func pollPendingRequest() {
        refreshCapturedMessages()
        upgradeToMoreCompleteVersionIfNeeded()

        guard let request = MessageStore.readPendingRequest(),
              request.nonce != lastHandledRequestNonce else { return }

        lastHandledRequestNonce = request.nonce
        Task { await load(messageID: request.messageID) }
    }

    /// 当前显示的是空壳版本时，换成同一封里最完整的那份。
    private func upgradeToMoreCompleteVersionIfNeeded() {
        guard let current = currentMessage,
              let internetMessageID = currentInternetMessageID,
              let best = MessageStore.mostComplete(forInternetMessageID: internetMessageID),
              best.id != current.id,
              best.byteCount > current.byteCount
        else { return }

        Task { await load(messageID: best.id) }
    }

    private func markCurrentRequestHandled() {
        lastHandledRequestNonce = MessageStore.readPendingRequest()?.nonce
    }

    // MARK: - 已捕获列表

    func refreshCapturedMessages(force: Bool = false) {
        let directory = SharedPaths.messages
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
        let stamp = attributes?[.modificationDate] as? Date

        if !force, let stamp, stamp == lastMessagesDirectoryStamp {
            return
        }
        lastMessagesDirectoryStamp = stamp
        capturedMessages = MessageStore.all()
    }

    // MARK: - 翻译

    /// 开发者模式关闭时强制用正式的 Apple 翻译 ——
    /// 「标记替换 / 原样返回」只是调试用的，不能让正常用户翻出一堆〖0〗。
    private var effectiveEngine: TranslationEngine {
        DeveloperMode.isOn ? engineChoice.engine : AppleTranslationEngine()
    }

    /// 开发者模式开关变化时调用：引擎的选择范围变了，需要重翻一次。
    func developerModeDidChange() {
        restartTranslation()
    }

    func restartTranslation() {
        translationTask?.cancel()
        guard let analysis else { return }

        let engine = effectiveEngine
        translationTask = Task { [weak self] in
            guard let self else { return }
            await self.translate(analysis: analysis, engine: engine)
        }
    }

    private func translate(analysis: EmailAnalysis, engine: TranslationEngine) async {
        let token = UUID()
        runToken = token
        let segments = analysis.segments

        guard !segments.isEmpty else {
            guard runToken == token else { return }
            inspection = EmailInspector.apply(translations: [:], to: analysis)
            translationStatus = .failed("这封邮件没有提取到可翻译的片段")
            return
        }

        // 引擎看不到上下文时，把孤立虚词剔出去（保留原文）——
        // 翻错比不翻更糟。LLM 有上下文，这类片段交给它翻。
        let engineSegments = engine.hasFullContext
            ? segments
            : segments.filter { !$0.isContextlessOrphan }

        translationStatus = .running(done: 0, total: engineSegments.count)

        do {
            let translated = try await engine.translate(
                segments: engineSegments,
                sourceLanguage: nil,
                targetLanguage: TranslationLanguages.simplifiedChinese,
                progress: { [weak self] done, total in
                    Task { @MainActor in
                        self?.translationStatus = .running(done: done, total: total)
                    }
                }
            )

            try Task.checkCancellation()
            guard runToken == token else { return }

            let translations = Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0.targetText) })
            inspection = EmailInspector.apply(translations: translations, to: analysis)
            translationStatus = .idle
        } catch is CancellationError {
            // 用户切了引擎或换了邮件，静默丢弃
        } catch {
            guard runToken == token else { return }
            // 失败时仍然把原文渲染出来，并把原因讲清楚 ——
            // 总比一个空窗格好，用户至少能看到邮件内容。
            inspection = EmailInspector.apply(translations: [:], to: analysis)
            translationStatus = .failed(Self.describe(error))
        }
    }

    // MARK: - 自检

    @discardableResult
    func runDiagnostics(allowDownloadTrigger: Bool) async -> TranslationDiagnostics.Report? {
        guard let analysis, !analysis.segments.isEmpty else { return nil }

        let report = await TranslationDiagnostics.probe(
            segments: analysis.segments,
            engine: engineChoice.engine,
            allowDownloadTrigger: allowDownloadTrigger
        )

        DiagnosticLog.append(report.text, label: "翻译链路自检（引擎：\(engineChoice.label)）")
        return report
    }

    // MARK: - 内部

    private func analyze(data: Data) async throws {
        state = .loading

        let analysis = try await Task.detached(priority: .userInitiated) {
            try EmailInspector.analyze(rawMessage: data)
        }.value

        self.analysis = analysis
        self.sourceBytes = data.count
        self.state = .loaded

        // 先用原样结果占位，再用引擎的结果替换
        self.inspection = EmailInspector.apply(translations: [:], to: analysis)
        restartTranslation()
    }

    private static func describe(_ error: Error) -> String {
        if let engineError = error as? TranslationEngineError {
            return engineError.description
        }
        return String(describing: error)
    }
}

/// 诊断日志落盘。
///
/// 位置和探针日志放一起，这样"扩展有没有拿到邮件"和"翻译有没有通"
/// 两件事在同一个地方看。
enum DiagnosticLog {

    static var directory: URL { SharedPaths.logs }

    static var translationURL: URL { directory.appendingPathComponent("translation-selftest.log") }

    static func append(_ text: String, label: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = """

        ══════════════════════════════════════════════════
        [\(stamp)] \(label)
        ══════════════════════════════════════════════════

        """
        let payload = Data((header + text).utf8)

        if let handle = try? FileHandle(forWritingTo: ensureFile()) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        }
    }

    private static func ensureFile() -> URL {
        let url = translationURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }
}
