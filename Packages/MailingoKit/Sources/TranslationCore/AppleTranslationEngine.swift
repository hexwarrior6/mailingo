import EmailCore
import Foundation
import Translation

/// Apple 系统内置翻译引擎（V1 默认，方案 §7）。
///
/// 优点：原生能力、无需 API Key、无 API 成本、延迟低、支持离线语言包。
/// 代价：macOS 15 上拿 session 必须绕 SwiftUI（见 `AppleTranslationSessionBroker`）。
public struct AppleTranslationEngine: TranslationEngine {

    public let id = "apple.translation.v1"
    public let displayName = "Apple 翻译（系统内置）"

    /// 每批段数。
    ///
    /// Apple 的批量接口一次塞太多会被限流甚至超时，而**单批失败会让整封信失败**，
    /// 所以切小、逐批上报进度，让 UI 能边出边显示。20 是保守值，
    /// 具体上限靠实测调整（方案 §8 Spike S2 的产出之一）。
    private let batchSize: Int

    public init(batchSize: Int = 20) {
        self.batchSize = batchSize
    }

    /// broker 是 `@MainActor` 隔离的，所以不能存成普通属性 —— 构造器是非隔离的，
    /// 在 Swift 6 语言模式下这样引用 `shared` 会报错。用的时候 await 取一下即可：
    /// 它是引用类型且 Sendable，跨 await 持有没问题。
    private var broker: AppleTranslationSessionBroker {
        get async { await AppleTranslationSessionBroker.shared }
    }

    // MARK: - 可用性

    public func availability(source: Locale.Language?, target: Locale.Language) async -> TranslationAvailability {
        let system = LanguageAvailability()

        if let source {
            return Self.map(await system.status(from: source, to: target))
        }

        // 源语言未知：只能先粗判"目标语言是否在系统支持列表里"。
        // 真正的语言对判定要等检测出源语言之后（见 `translate`）。
        let supported = await system.supportedLanguages
        let targetCode = target.languageCode?.identifier
        let isSupported = supported.contains { $0.languageCode?.identifier == targetCode }
        return isSupported ? .supported : .unsupported
    }

    /// 触发语言包准备。语言包没装时，这一步会带来系统的下载确认弹窗 ——
    /// 弹窗需要一个真实父窗口，所以宿主视图必须挂在可见窗口里。
    public func prepare(source: Locale.Language?, target: Locale.Language) async throws {
        let broker = await self.broker
        try await broker.runVoid(source: source, target: target) { session in
            try await session.prepareTranslation()
        }
    }

    /// **只验证"能不能拿到 session"**，不做任何实际翻译。
    ///
    /// 存在的理由：语言包没装时，正常翻译路径会停在系统下载弹窗之前，于是
    /// SwiftUI 桥接（`.translationTask` 到底会不会被触发、session 会不会到）
    /// 这个最大的风险点就**完全没被验证到**。这个探针把风险点单独拎出来测：
    /// 只要拿到 session 就算通过，不碰 `translate`、不触发下载。
    public func probeSession(timeout: TimeInterval = 15) async -> SessionProbeResult {
        let started = Date()

        do {
            let broker = await self.broker
            try await broker.runVoid(
                source: nil,
                target: TranslationLanguages.simplifiedChinese,
                sessionTimeout: timeout
            ) { _ in
                // 拿到 session 就是目的；不做任何调用，避免触发语言包下载。
            }
            return .reached(elapsed: Date().timeIntervalSince(started))
        } catch {
            return .failed(
                elapsed: Date().timeIntervalSince(started),
                reason: (error as? TranslationEngineError)?.description ?? String(describing: error)
            )
        }
    }

    /// 连续取多次 session。
    ///
    /// 这是针对「第一次翻译正常、之后全部超时」那个 bug 的回归探针：
    /// 如果配置没有真正"变化"，第 2 次之后就会各超时一次。
    public func probeSessionRepeatedly(times: Int = 3) async -> [SessionProbeResult] {
        var results: [SessionProbeResult] = []
        for _ in 0..<max(1, times) {
            results.append(await probeSession())
        }
        return results
    }

    public enum SessionProbeResult: Sendable {
        case reached(elapsed: TimeInterval)
        case failed(elapsed: TimeInterval, reason: String)

        public var succeeded: Bool {
            if case .reached = self { return true }
            return false
        }

        public var summary: String {
            switch self {
            case .reached(let elapsed):
                String(format: "✅ 拿到 session（%.2f 秒）—— SwiftUI 桥接工作正常", elapsed)
            case .failed(let elapsed, let reason):
                String(format: "❌ 未能拿到 session（%.2f 秒）：%@", elapsed, reason)
            }
        }
    }

    // MARK: - 翻译

    public func translate(
        segments: [TranslationSegment],
        sourceLanguage: Locale.Language?,
        targetLanguage: Locale.Language,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [TranslatedSegment] {
        guard !segments.isEmpty else { return [] }

        // 1) 源语言：优先用调用方给的，否则自己检测
        let source = sourceLanguage ?? LanguageDetector.detect(in: segments)

        // 2) 可用性。不支持就早失败，别翻到一半才报错。
        switch await availability(source: source, target: targetLanguage) {
        case .unsupported:
            throw TranslationEngineError.unsupportedLanguagePair(
                source: source?.minimalIdentifier,
                target: targetLanguage.minimalIdentifier
            )
        case .installed, .supported:
            break
        }

        // 3) 分批，但**整次翻译只借一次 session**。
        //
        //    早先是"每批要一次 session"，两个坏处：
        //    - 每次取 session 都要过一次 SwiftUI 的 configuration 触发，往返多；
        //    - 一旦某次卡住，超时是按次算的，15 批就是 15 次超时叠加，
        //      UI 上表现为"卡在 0/N 很久然后报错"。
        //    现在把整个循环放进一次 session 里跑完，progress 照常逐批上报。
        let broker = await self.broker
        let batches = Self.batches(segments, size: batchSize)
        let total = segments.count

        let collected = try await broker.run(source: source, target: targetLanguage) { session in
            var collected: [Int: String] = [:]
            var completed = 0

            for batch in batches {
                // 让用户切邮件时能立刻停下
                try Task.checkCancellation()

                let requests = batch.map {
                    TranslationSession.Request(sourceText: $0.sourceText, clientIdentifier: String($0.id))
                }
                let responses = try await session.translations(from: requests)

                // 4) 按 clientIdentifier 对账，**不依赖返回顺序** ——
                //    将来接 LLM 的引擎不保证保序，这里先立好规矩。
                for response in responses {
                    guard let identifier = response.clientIdentifier, let id = Int(identifier) else { continue }
                    collected[id] = response.targetText
                }

                completed += batch.count
                progress(completed, total)
            }

            return collected
        }

        // 5) 引擎没回的片段保持原文，避免调用方拿到不完整的字典
        return Self.assemble(segments: segments, collected: collected)
    }

    // MARK: - 纯逻辑（单独抽出来以便脱离系统服务单测）

    /// 把片段切成若干批。
    static func batches(_ segments: [TranslationSegment], size: Int) -> [[TranslationSegment]] {
        guard size > 0 else { return segments.isEmpty ? [] : [segments] }
        return stride(from: 0, to: segments.count, by: size).map {
            Array(segments[$0..<min($0 + size, segments.count)])
        }
    }

    /// 把引擎返回的译文按 id 装配回完整结果。
    ///
    /// 两条不能省的保证：
    /// - **顺序跟入参一致**（调用方拿到的数组与传入的 segments 一一对应）；
    /// - **缺失的片段回退成原文**，而不是凭空丢掉 —— 丢一段就等于邮件里少一句话。
    static func assemble(segments: [TranslationSegment], collected: [Int: String]) -> [TranslatedSegment] {
        segments.map { segment in
            TranslatedSegment(id: segment.id, targetText: collected[segment.id] ?? segment.sourceText)
        }
    }

    // MARK: - 私有

    private static func map(_ status: LanguageAvailability.Status) -> TranslationAvailability {
        switch status {
        case .installed: .installed
        case .supported: .supported
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }
}
