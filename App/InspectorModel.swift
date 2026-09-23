import EmailCore
import Foundation
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

        var isRealTranslation: Bool { self == .apple }
    }

    enum LoadState {
        case idle
        case loading
        case failed(String)
        case loaded
    }

    /// 翻译进度。真实翻译是异步且有耗时的，UI 必须能看到"翻到哪了"。
    enum TranslationStatus: Equatable {
        case idle
        case running(done: Int, total: Int)
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var inspection: EmailInspection?
    @Published private(set) var translationStatus: TranslationStatus = .idle

    @Published var engineChoice: EngineChoice = .apple {
        didSet {
            guard oldValue != engineChoice else { return }
            restartTranslation()
        }
    }

    private(set) var sourceURL: URL?
    private(set) var sourceBytes: Int = 0

    private var analysis: EmailAnalysis?
    private var translationTask: Task<Void, Never>?
    /// 每次翻译运行发一个令牌。取消不一定能立刻终止正在 await 的调用，
    /// 所以结果回来时要确认"我还是当前那一次"，否则旧邮件的译文会覆盖新邮件。
    private var runToken = UUID()

    // MARK: - 载入

    /// 从 appex 的沙盒容器里读最近一封真实邮件。
    func loadFromProbeLog() async {
        let url = ProbeLog.lastMessageURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            state = .failed("""
            还没拿到邮件。

            请确认 Mail 里的 Mailingo 扩展已启用，并打开几封邮件 —— appex 会把最近一封的\
            原始 MIME 写到这里：
            \(url.path)
            """)
            return
        }

        do {
            try await analyze(data: Data(contentsOf: url), sourceURL: url)
        } catch {
            state = .failed("读取失败：\(error.localizedDescription)")
        }
    }

    /// 从用户选的文件读（用于喂自造的 fixture 或邮件样本）。
    func load(fileURL: URL) async {
        do {
            try await analyze(data: Data(contentsOf: fileURL), sourceURL: fileURL)
        } catch {
            state = .failed("读取失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 翻译

    func restartTranslation() {
        translationTask?.cancel()
        guard let analysis else { return }

        let engine = engineChoice.engine
        translationTask = Task { [weak self] in
            guard let self else { return }
            await self.translate(analysis: analysis, engine: engine)
        }
    }

    private func translate(analysis: EmailAnalysis, engine: TranslationEngine) async {
        let token = UUID()
        runToken = token
        let segments = analysis.segments

        // 没有片段就别折腾引擎了，直接给一个原样的结果
        guard !segments.isEmpty else {
            guard runToken == token else { return }
            inspection = EmailInspector.apply(translations: [:], to: analysis)
            translationStatus = .failed("这封邮件没有提取到可翻译的片段")
            return
        }

        translationStatus = .running(done: 0, total: segments.count)

        // 先立刻用"原文"把结果渲染出来，然后随着译文到达逐步替换 ——
        // 用户马上看得到排版，而不是对着空窗格等。
        var translations: [Int: String] = [:]

        do {
            let translated = try await engine.translate(
                segments: segments,
                sourceLanguage: nil,
                targetLanguage: TranslationLanguages.simplifiedChinese,
                progress: { [weak self] done, total in
                    Task { @MainActor in
                        self?.translationStatus = .running(done: done, total: total)
                    }
                }
            )

            translations = Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0.targetText) })
            try Task.checkCancellation()

            // 旧运行的结果不许覆盖新邮件
            guard runToken == token else { return }
            inspection = EmailInspector.apply(translations: translations, to: analysis)
            translationStatus = .idle
        } catch is CancellationError {
            // 用户切了引擎或换了邮件，静默丢弃
        } catch {
            // 失败时仍然把原文渲染出来，并把原因讲清楚 ——
            // 总比一个空窗格好，用户至少能看到邮件内容。
            guard runToken == token else { return }
            inspection = EmailInspector.apply(translations: [:], to: analysis)
            translationStatus = .failed(Self.describe(error))
        }
    }

    // MARK: - 自检

    /// 跑一遍翻译链路自检并落盘，便于不开 UI 也能确认引擎是否真的通了。
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

    private func analyze(data: Data, sourceURL: URL?) async throws {
        state = .loading

        // 解析放到后台：营销邮件动辄几百 KB，别卡住 UI
        let analysis = try await Task.detached(priority: .userInitiated) {
            try EmailInspector.analyze(rawMessage: data)
        }.value

        self.analysis = analysis
        self.sourceURL = sourceURL
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
/// 位置刻意和探针日志放一起（`~/Library/Logs/Mailingo/`），
/// 这样"扩展有没有拿到邮件"和"翻译有没有通"两件事在同一个地方看。
enum DiagnosticLog {

    static var directory: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Mailingo", isDirectory: true)
    }

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
