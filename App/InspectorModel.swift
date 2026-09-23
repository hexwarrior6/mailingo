import AppKit
import Cache
import EmailCore
import Foundation
import MailIntegration
import os
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

    /// 缓存命中情况，给开发者面板看。
    enum CacheStatus: Equatable {
        case unknown
        case hit
        case missed
        case stored
        /// 用户点了「重新翻译」，这次没查缓存。
        case bypassed
    }
    @Published private(set) var cacheStatus: CacheStatus = .unknown

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
    static let closesWithMailKey = "inspector.closesWithMail"

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

    /// 当前正在跑的载入任务。新的一次载入会先取消它 ——
    /// 快速切邮件时要**直接跳到最后一封**，不能把中间每一封都加载完。
    /// 详见 `load(messageID:manual:ignoringCache:)`。
    private var loadTask: Task<Void, Never>?

    /// 载入的代次。每次载入换一个新值；每个 await 回来都要对一次，
    /// 对不上说明自己已经被取代了，什么都不许写。
    ///
    /// 为什么光靠 `cancel()` 不够：取消是协作式的，旧任务可能正卡在某个 await
    /// 上，取消后还要过一会儿才真的退出。中间这段时间足够它把旧邮件的内容
    /// 写进 `inspection`，把用户刚切过去的新邮件盖掉。
    private var loadToken = UUID()

    /// Mail 关掉阅读窗口时，是否也把我们的窗口关掉（轻量化：窗口一关就退出）。
    ///
    /// 默认**开**。它只有在「跟随 Mail」打开时才起作用（信号就来自那次轮询），
    /// 而「跟随 Mail」本身默认是关的 —— 所以不会有人被动地被关窗口。
    @Published var closesWithMail: Bool =
        UserDefaults.standard.object(forKey: InspectorModel.closesWithMailKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(closesWithMail, forKey: Self.closesWithMailKey)
            noViewerStreak = 0
        }
    }

    /// 这次会话里**见到过** Mail 的阅读窗口。
    ///
    /// 这是自动关窗的前置条件，缺了它会误伤：从 Finder 打开 Mailingo 翻看
    /// 已捕获的邮件时，Mail 可能压根没开 —— 那不是"窗口被关掉了"，
    /// 我们不该把用户的窗口收走。
    private var hasSeenMailViewer = false

    /// 连续多少次轮询看到"没有阅读窗口"。用来去抖，避免 Mail 一瞬间的状态
    /// 抖动就把窗口关掉。
    private var noViewerStreak = 0

    /// 连续多少次才认定"Mail 的阅读窗口真的关了"。
    /// 轮询间隔 0.5 秒，所以 3 次 ≈ 1.5 秒。
    private static let noViewerStreakThreshold = 3

    /// 当前正在跑的「问 Mail 选中了哪一封」的查询。
    /// 用来在发起新查询前取消旧的，避免 AppleScript 在串行队列上堆成一串。
    private var selectionQueryTask: Task<MailSelection, Error>?

    /// 邮件目录的监听源。Mail 一交来新邮件就立刻去问选中项（见
    /// `startWatchingMessagesDirectory`）。跟着 App 活到退出，不需要显式取消。
    private var messagesWatcher: DispatchSourceFileSystemObject?

    /// 跟随与载入的轻量追踪。
    ///
    /// 走 os_log 而不是 `ProbeLog` —— 后者每次调用都 `fsync`，高频打点会把主线程拖住。
    /// 看的时候用 `make stream`（就是按 subsystem 过滤的 `log stream`）。
    /// 存在的意义：闪一下这类问题全靠时序，光看代码猜不出来。
    private let trace = Logger(subsystem: "com.zhuyuhao.Mailingo", category: "follow")

    /// 上一次因为"目录有动静"而触发跟随的时间，用来限流。
    private var lastMessagesActivity = Date.distantPast
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
    /// 缓存清理策略（用户在设置里改，存在 UserDefaults）。
    static let cacheMaxAgeDaysKey = "cache.maxAgeDays"
    static let cacheMaxSizeMBKey = "cache.maxSizeMB"

    private var cachePolicy: CachePolicy {
        let defaults = UserDefaults.standard
        let days = (defaults.object(forKey: Self.cacheMaxAgeDaysKey) as? Int) ?? CachePolicy.default.maxAgeDays
        let megabytes = (defaults.object(forKey: Self.cacheMaxSizeMBKey) as? Int) ?? CachePolicy.default.maxSizeMB
        return CachePolicy(maxAgeDays: days, maxSizeMB: megabytes)
    }
    /// 上一次从 Mail 读到的选中项，用来判断"选择变了没有"。
    private var lastMailSelectionID: String?
    /// 用户手动选过邮件之后，先别让自动跟随把他拉回去 ——
    /// 直到 Mail 那边的选中项真的变了，才恢复跟随。
    private var followSuppressed = false
    /// messages 目录的上次修改时间，避免每次轮询都全量重读元数据。
    private var lastMessagesDirectoryStamp: Date?

    // MARK: - 启动

    func bootstrap() async {
        // 启动时先按策略清理一次缓存，避免长期不打开设置就一直不清理
        _ = await TranslationCache.shared.purge(policy: cachePolicy)
        startWatchingMessagesDirectory()
        refreshCapturedMessages(force: true)
        await loadMostRecent()
        // 启动时自检一次，但**不触发系统下载弹窗** ——
        // 只是把「语言包装了没」这类事实记下来，用户没要求就别打扰他。
        await runDiagnostics(allowDownloadTrigger: false)
    }

    // MARK: - 邮件目录监听

    /// 目录一动就立刻去问 Mail，而不是干等下一次轮询。
    ///
    /// ## 它只在"来了新邮件"时有用 —— 别指望它解决切邮件卡顿
    ///
    /// 实测（2026-09-24，20 秒连续切邮件）**它一次都没触发过**：
    /// Mail 只会为**还没解码过**的邮件调 `decodedMessage`，而这几个来回切的
    /// 邮件早就捕获过了，不会再落盘。所以"在已看过的邮件之间切换"这个场景
    /// 它帮不上忙，真正的原因是主线程被冻住（见 `applyOffMainThread`）。
    ///
    /// 保留它是因为"第一次打开一封新邮件"时确实能快一点：Mail 把它交给扩展、
    /// 扩展落盘，目录就有动静，我们立刻去问一次选中项，比等定时器早。
    ///
    /// 定时器是主力，这个是锦上添花。
    private func startWatchingMessagesDirectory() {
        let directory = SharedPaths.messages
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // O_EVTONLY：只监听事件、不要读权限，也不会阻止卷被卸载
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.messagesDirectoryDidChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        messagesWatcher = source
    }

    private func messagesDirectoryDidChange() {
        // 限流。Mail 打开一个会话时会**连着解码好几封**（实测一次能解十几封），
        // 每封都去问一次选中项纯属浪费 —— 反正问回来的是同一个答案。
        let now = Date()
        guard now.timeIntervalSince(lastMessagesActivity) > 0.2 else { return }
        lastMessagesActivity = now
        trace.notice("邮件目录有动静 → 立刻问 Mail 选中了哪一封")

        // 顺带刷新已捕获列表，不必等下一次 timer
        refreshCapturedMessages(force: true)
        pollMailSelection()
    }

    // MARK: - 载入

    /// 载入最近捕获的那封。走缓存 —— 启动时不该为了看一眼就重翻一遍。
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
    /// ## 快速切邮件时为什么要「取消上一个」
    ///
    /// 在 Mail 左边点得快的时候，右边必须**直接跳到最后一封**，而不是把中间
    /// 每一封都加载完再跟上。这里用两道闸：
    ///
    /// 1. **取消**上一个载入任务（`loadTask`）。解析是纯 CPU 活，取消掉就不再
    ///    白烧 CPU —— 配合 `EmailInspector.analyze` 里的 `checkCancellation`。
    /// 2. **代次**（`loadToken`）。取消是协作式的：旧任务可能正卡在某个 await 上，
    ///    取消后还要过一会儿才真的退出。所以每个 await 回来都要对一次代次，
    ///    对不上就**什么都不写**，绝不让旧邮件的内容盖掉新邮件的。
    ///
    /// - Parameter manual: 是不是用户手动选的（下拉里点、点横幅、拖文件）。
    ///   手动选过之后要**先别让自动跟随把人拉回去** ——
    ///   否则你刚点开另一封，下一秒就被 Mail 的选中项拽回来。
    /// - Parameter ignoringCache: 见 `retranslate()`。
    func load(messageID: String, manual: Bool = true, ignoringCache: Bool = false) async {
        // 先把上一个载入掐断。注意 `cancel()` 只是"请求取消"，旧任务未必立刻停，
        // 所以下面还要靠代次兜底。
        loadTask?.cancel()

        // 连它派生出来的翻译一起掐。
        //
        // 为什么不能只靠 `restartTranslation()` 去掐：如果这次载入是**在解析
        // 中途**被取消的，它根本没机会走到 `restartTranslation()`，上一封的翻译
        // 就会继续跑，甚至在新邮件已经显示之后才把旧译文写回 `inspection`。
        // 换掉 `runToken` 是把那条路彻底堵死 —— 在途的旧译文回来时对不上号，
        // 只能被丢弃（但它的缓存写入仍然有效，不浪费）。
        translationTask?.cancel()
        runToken = UUID()

        let token = UUID()
        loadToken = token

        trace.notice("load 开始 \(messageID, privacy: .public)（已取消上一个）")

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(
                messageID: messageID,
                manual: manual,
                ignoringCache: ignoringCache,
                token: token
            )
        }
        loadTask = task
        await task.value
    }

    /// 真正干活的那一半。所有 await 回来后都要重新确认自己还是"当前那一次"。
    private func performLoad(
        messageID: String,
        manual: Bool,
        ignoringCache: Bool,
        token: UUID
    ) async {
        if manual { followSuppressed = true }

        let stored = capturedMessages.first { $0.id == messageID }
            ?? MessageStore.all().first { $0.id == messageID }

        guard let stored else {
            guard loadToken == token else { return }
            state = .failed("找不到邮件 \(messageID)，可能已经被清理掉了。")
            return
        }
        guard let raw = MessageStore.rawMessage(id: messageID) else {
            guard loadToken == token else { return }
            state = .failed("邮件 \(messageID) 的原始内容读不出来。")
            return
        }

        // 已经被更新的一次载入取代 → 连 currentMessage 都不要动
        guard loadToken == token else { return }

        currentMessage = stored
        currentInternetMessageID = stored.internetMessageID
        do {
            try await analyze(data: raw, ignoringCache: ignoringCache, token: token)
        } catch is CancellationError {
            // 被取代了，静默丢弃 —— 这不是错误，是预期行为
            trace.notice("载入被取代 \(messageID, privacy: .public)（已取消，不再落地）")
        } catch {
            guard loadToken == token else { return }
            state = .failed("解析失败：\(error.localizedDescription)")
        }
    }

    /// 用户从「打开 .eml…」选的文件。
    func load(fileURL: URL) async {
        loadTask?.cancel()
        let token = UUID()
        loadToken = token

        currentMessage = nil
        currentInternetMessageID = nil
        do {
            try await analyze(data: Data(contentsOf: fileURL), ignoringCache: true, token: token)
        } catch is CancellationError {
            // 被取代，静默丢弃
        } catch {
            guard loadToken == token else { return }
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

        // **单飞**：上一次查询还没回来，这一拍就整个跳过。
        //
        // 为什么不"取消上一次、重新发一次"：查询本身读的就是**此刻**的选中项，
        // 所以上一拍的结果不会过期，没有取消的必要。反过来，取消重发有个致命
        // 后果 —— 当查询比轮询间隔还慢时（Mail 忙、或脚本挂着），每一拍都会把
        // 上一拍取消掉，于是**永远拿不到任何结果**，跟随直接失效。
        // 真正需要"取消上一个"的是**载入**，那个在 `load` 里做。
        guard selectionQueryTask == nil else {
            trace.notice("上一次查询还没回来 → 跳过这一拍（跟随可能因此变慢）")
            return
        }

        let query = Task { try await MailSelectionMonitor.shared.currentSelection() }
        selectionQueryTask = query

        Task { [weak self] in
            guard let self else { return }

            let outcome: Result<MailSelection, Error>
            do {
                outcome = .success(try await query.value)
            } catch {
                outcome = .failure(error)
            }

            // 查询一结束就放开这个槽 —— 后面的载入不该占着它，
            // 否则载入期间的新选中项要等下一次轮询才被发现。
            self.selectionQueryTask = nil

            await self.followSelection(outcome)
        }
    }

    /// 拿到一次查询结果之后该做什么。
    private func followSelection(_ outcome: Result<MailSelection, Error>) async {
        // 查询期间用户可能把「跟随 Mail」关掉了，那就别再切了
        guard followsMailSelection else { return }

        switch outcome {
        case .success(let selection):
            // 见到阅读窗口了 —— 之后它消失才算"被关掉"
            hasSeenMailViewer = true
            noViewerStreak = 0

            // Mail 的选中项变了 → 解除之前的手动抑制
            if selection.internetMessageID != lastMailSelectionID {
                lastMailSelectionID = selection.internetMessageID
                followSuppressed = false
            }

            guard !followSuppressed else {
                mailFollowStatus = .following
                trace.debug("跟随被抑制（用户手动选过）→ 这次不切")
                return
            }

            guard let message = MessageStore.message(
                matchingInternetMessageID: selection.internetMessageID
            ) else {
                // Mail 选中了，但那封邮件扩展还没收到（刚点开、还在解码）
                mailFollowStatus = .waiting("Mail 选中的邮件还没同步过来…")
                return
            }

            mailFollowStatus = .following
            // 稳态（选中的就是当前这封）**刻意不打日志** —— 它每 0.5 秒
            // 就会来一次，打出来只会把真正有用的行淹掉。诊断时"没有 load 开始"
            // 本身就说明是稳态。
            guard message.id != currentMessage?.id else { return }
            // 这一次 `load` 会自动取消上一次载入 —— 所以快速切邮件时
            // 右边是"直接跳到最后一封"，不会把中间每一封都加载完。
            await load(messageID: message.id, manual: false)

        case .failure(let error):
            guard let selectionError = error as? MailSelectionError else {
                mailFollowStatus = .failed(String(describing: error))
                return
            }
            switch selectionError {
            case .automationDenied:
                noViewerStreak = 0
                mailFollowStatus = .permissionDenied

            case .noViewer, .mailNotRunning:
                // Mail 的阅读窗口不在了（或 Mail 自己退了）。
                // 这既是"等待"状态，也可能是"该收摊了"的信号。
                mailFollowStatus = .waiting(selectionError.description)
                handleMailViewerPossiblyGone()

            default:
                noViewerStreak = 0
                mailFollowStatus = selectionError.isTransient
                    ? .waiting(selectionError.description)
                    : .failed(selectionError.description)
            }
        }
    }

    /// Mail 的阅读窗口不见了 —— 判断要不要跟着收摊。
    ///
    /// 两道保险，缺一都会误伤：
    ///
    /// 1. **必须曾经见过阅读窗口**。从 Finder 打开 Mailingo 翻看已捕获的邮件时，
    ///    Mail 可能压根没开 —— 那不是"窗口被关掉"，不该把用户的窗口收走。
    /// 2. **必须连续几次都是这样**。Mail 在启动、切换、忙碌时都可能一瞬间
    ///    报不出阅读窗口，抖一下就把窗口关掉太粗暴。
    private func handleMailViewerPossiblyGone() {
        guard closesWithMail, hasSeenMailViewer else { return }

        noViewerStreak += 1
        guard noViewerStreak >= Self.noViewerStreakThreshold else { return }

        noViewerStreak = 0
        hasSeenMailViewer = false   // 关掉之后要重新"见过"才会再触发
        trace.notice("Mail 的阅读窗口关掉了（连续 \(Self.noViewerStreakThreshold) 次确认）→ 关闭本窗口")

        // 窗口是 SwiftUI 的 Window 场景在管，AppKit 这边关不了它 ——
        // 发通知让 RootView 用 `dismiss()` 收掉（然后 App 会因为
        // 「最后一个窗口关闭即退出」而退出）。
        NotificationCenter.default.post(name: .mailingoCloseMainWindow, object: nil)
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

    /// - Parameter ignoringCache: 见 `retranslate()`。
    func restartTranslation(ignoringCache: Bool = false) {
        translationTask?.cancel()
        guard let analysis else { return }

        let engine = effectiveEngine
        translationTask = Task { [weak self] in
            guard let self else { return }
            await self.translate(analysis: analysis, engine: engine, ignoringCache: ignoringCache)
        }
    }

    /// 「重新翻译」：**绕过缓存**，强制走一遍引擎。
    ///
    /// 缓存让重复翻译变成空操作，所以必须留一个真正的强制入口 ——
    /// 否则用户碰到一个翻坏的译文就没有任何手段纠正它了。
    ///
    /// 重翻的是**你正在看的那一封**，不是"最新捕获的那封"：
    /// 会话里来回好几封时，点一下 ↻ 就被拽到别的邮件上会很意外。
    /// 同时先刷一次列表，好让 Mail 后来补上的完整版能被读到。
    func retranslate() async {
        refreshCapturedMessages(force: true)
        guard let id = currentMessage?.id else {
            // 正在看导入的 .eml（或还没载入任何邮件）：就地把当前分析重翻一遍
            restartTranslation(ignoringCache: true)
            return
        }
        await load(messageID: id, ignoringCache: true)
    }

    private func translate(
        analysis: EmailAnalysis,
        engine: TranslationEngine,
        ignoringCache: Bool = false
    ) async {
        let token = UUID()
        runToken = token
        let segments = analysis.segments

        guard !segments.isEmpty else {
            guard runToken == token else { return }
            // `apply` 只可能因被取代而抛；`translate` 本身不抛，就地消化
            guard let applied = try? await applyOffMainThread(translations: [:], to: analysis)
            else { return }
            inspection = applied
            translationStatus = .failed("这封邮件没有提取到可翻译的片段")
            return
        }

        // 引擎看不到上下文时，把孤立虚词剔出去（保留原文）——
        // 翻错比不翻更糟。LLM 有上下文，这类片段交给它翻。
        let engineSegments = engine.hasFullContext
            ? segments
            : segments.filter { !$0.isContextlessOrphan }

        // ── 查缓存 ──────────────────────────────────────────────
        // 身份优先用 Message-ID（同一封邮件的两次交付落到同一个键），
        // 内容指纹用 HTML 哈希（HTML 变了就重翻）。
        let sourceHash = TranslationCache.contentHash(of: analysis.originalHTML)
        let messageKey = currentInternetMessageID.map(MIMEHeaders.normalizeMessageID) ?? sourceHash
        let cacheKey = CacheKey(
            messageKey: messageKey,
            targetLanguage: TranslationLanguages.simplifiedChinese.minimalIdentifier,
            engineID: engine.id,
            pipelineVersion: CacheKey.currentPipelineVersion
        )

        if !ignoringCache,
           let cached = await TranslationCache.shared.lookup(cacheKey, sourceHash: sourceHash),
           !cached.isEmpty {
            // 守卫要在 await **之后**再对一次：apply 要分词，一封 287 KB 的
            // 邮件就要几百毫秒，中间足够用户切走，过期结果绝不能落地。
            guard let applied = try? await applyOffMainThread(translations: cached, to: analysis)
            else { return }
            guard runToken == token else { return }
            inspection = applied
            translationStatus = .idle
            cacheStatus = .hit
            return
        }
        cacheStatus = ignoringCache ? .bypassed : .missed

        translationStatus = .running(done: 0, total: engineSegments.count)

        do {
            let translated = try await engine.translate(
                segments: engineSegments,
                sourceLanguage: nil,
                targetLanguage: TranslationLanguages.simplifiedChinese,
                progress: { [weak self] done, total in
                    Task { @MainActor in
                        // 同样要按代次过滤：被取代的那次翻译还在跑时，
                        // 它的进度不该盖到新邮件头上
                        guard let self, self.runToken == token else { return }
                        self.translationStatus = .running(done: done, total: total)
                    }
                }
            )

            try Task.checkCancellation()
            guard runToken == token else { return }

            let translations = Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0.targetText) })

            // 写缓存，然后按用户策略清理（超过天数或超过大小就淘汰最久未用的）
            await TranslationCache.shared.store(cacheKey, sourceHash: sourceHash, translations: translations)
            await TranslationCache.shared.purge(policy: cachePolicy)
            guard runToken == token else { return }
            cacheStatus = .stored

            let applied = try await applyOffMainThread(translations: translations, to: analysis)
            guard runToken == token else { return }
            inspection = applied
            translationStatus = .idle
        } catch is CancellationError {
            // 用户切了引擎或换了邮件，静默丢弃
        } catch {
            guard runToken == token else { return }
            // 失败时仍然把原文渲染出来，并把原因讲清楚 ——
            // 总比一个空窗格好，用户至少能看到邮件内容。
            //
            // 用 `try?`：这里已经在 catch 里、而 `translate` 本身不抛，
            // 所以只能就地消化。apply 唯一的失败原因是被取代 —— 那就什么都不写。
            guard let applied = try? await applyOffMainThread(translations: [:], to: analysis)
            else { return }
            guard runToken == token else { return }
            inspection = applied
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

    private func analyze(data: Data, ignoringCache: Bool = false, token: UUID) async throws {
        guard loadToken == token else { return }
        state = .loading

        let started = Date()
        trace.notice("解析开始 \(self.currentMessage?.id ?? "?", privacy: .public)（\(data.count / 1024) KB）")

        let analysis = try await analyzeOffMainThread(data)
        trace.notice("解析完成 \(self.currentMessage?.id ?? "?", privacy: .public)  用时 \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        // 解析是这段里最耗时的一步（MIME 解码 + HTML 分词）。回来之后必须
        // 重新确认自己还是"当前那一次"，否则旧邮件会盖掉用户已经切过去的新邮件。
        try Task.checkCancellation()
        guard loadToken == token else { return }

        // 先用原样结果占位，再用引擎的结果替换。
        //
        // 注意顺序：**占位算好之前不能离开 .loading**。否则那 1.5 秒里
        // state 是 .loaded、而 inspection 还是上一封的 —— 界面就会显示
        // 上一封的内容，正是"一闪而过"那种观感。
        let placeholder = try await applyOffMainThread(translations: [:], to: analysis)
        guard loadToken == token else { return }

        self.analysis = analysis
        self.sourceBytes = data.count
        self.inspection = placeholder
        self.state = .loaded
        trace.notice("load 落地 \(self.currentMessage?.id ?? "?", privacy: .public) → 界面切到这一封")
        restartTranslation(ignoringCache: ignoringCache)
    }

    /// 把解析挪到后台跑，并且**让它跟着当前任务一起被取消**。
    ///
    /// 用 `Task.detached` 是因为解析是纯 CPU 活，不该占主线程
    /// （`InspectorModel` 是 `@MainActor`）。但 detached 的任务
    /// **不会继承父任务的取消** —— 光 `await` 它的 `.value`，父任务被取消时
    /// 它照样跑到底。所以这里显式把两者接起来：父任务一取消，
    /// `onCancel` 就把 detached 任务也取消掉，`analyze` 里的
    /// `checkCancellation` 随即抛出。这样快速切邮件时，旧的解析会真的停，
    /// 而不是白烧一遍 CPU 再把结果丢掉。
    private func analyzeOffMainThread(_ data: Data) async throws -> EmailAnalysis {
        let task = Task.detached(priority: .userInitiated) {
            try EmailInspector.analyze(rawMessage: data)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 把译文写回 HTML 并做保真自检 —— **必须挪到后台**。
    ///
    /// `EmailInspector.apply` 是纯函数，但**很贵，而且贵得不显眼**：
    /// 实测一封 287 KB HTML 的邮件要 **1.55 秒**（切片 + 两遍标签序列比对）。
    /// 它跑在主 actor 上，会把整个界面连同轮询定时器一起冻住 —— 表现就是
    /// "点别的邮件没反应，要等它转完才切过去"。
    ///
    /// 每封邮件它会被调用两次（先用空译文占位、译文回来再写一次），
    /// 所以那封邮件实际冻了约 3 秒。
    ///
    /// **可以取消**：`apply` 里最贵的是保真自检的两趟分词（每份 HTML 一趟），
    /// 一封 287 KB 的邮件要 ~785 ms。用户切走后这份结果就没用了，取消掉能
    /// 立刻把那半个核还回来。`textRuns` / `tagSequence` 里都埋了取消检查。
    private func applyOffMainThread(
        translations: [Int: String],
        to analysis: EmailAnalysis
    ) async throws -> EmailInspection {
        let task = Task.detached(priority: .userInitiated) {
            try EmailInspector.apply(translations: translations, to: analysis)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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
