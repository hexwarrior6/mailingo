import Foundation

/// 假翻译引擎：把每个片段替换成带编号的标记。
///
/// 它不是玩具 —— 它是 M3 阶段**唯一能让"保真"可见**的手段：
/// 左边原文、右边每个文本节点都变成 `〖N〗`，你一眼就能看出
/// 「表格还在、图片还在、颜色还在、链接还在，只是文字被换掉了」。
///
/// 同时也是测试与 CI 的支柱：整条管线不需要 Apple Translation、不需要网络、
/// 不需要任何权限就能端到端跑通（方案 §6）。
public struct MarkerTranslationEngine: TranslationEngine {

    public let id = "fake.marker.v1"
    public let displayName = "标记替换（调试用）"

    private let template: @Sendable (Int) -> String

    /// - Parameter template: 第 N 段的替换文本，默认 `〖N〗`。
    ///   标注 `@Sendable` 是必须的：`TranslationEngine` 是 `Sendable`，
    ///   存一个非 Sendable 的闭包在 Swift 6 语言模式下是错误。
    public init(template: @escaping @Sendable (Int) -> String = { "〖\($0)〗" }) {
        self.template = template
    }

    public func availability(source: Locale.Language?, target: Locale.Language) async -> TranslationAvailability {
        .installed
    }

    public func translate(
        segments: [TranslationSegment],
        sourceLanguage: Locale.Language?,
        targetLanguage: Locale.Language,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [TranslatedSegment] {
        let total = segments.count
        var out: [TranslatedSegment] = []
        out.reserveCapacity(total)
        for (index, segment) in segments.enumerated() {
            out.append(TranslatedSegment(id: segment.id, targetText: template(segment.id)))
            progress(index + 1, total)
        }
        return out
    }
}

/// 原样返回的引擎，用于验证「不翻译时切片结果必须与原文逐字节相同」。
public struct IdentityTranslationEngine: TranslationEngine {
    public let id = "fake.identity.v1"
    public let displayName = "原样返回（测试用）"

    public init() {}

    public func availability(source: Locale.Language?, target: Locale.Language) async -> TranslationAvailability {
        .installed
    }

    public func translate(
        segments: [TranslationSegment],
        sourceLanguage: Locale.Language?,
        targetLanguage: Locale.Language,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [TranslatedSegment] {
        let total = segments.count
        var out: [TranslatedSegment] = []
        out.reserveCapacity(total)
        for (index, segment) in segments.enumerated() {
            out.append(TranslatedSegment(id: segment.id, targetText: segment.sourceText))
            progress(index + 1, total)
        }
        return out
    }
}

/// 会失败 / 会慢的引擎，用来验证 UI 的错误态与进度显示。
public struct FailingTranslationEngine: TranslationEngine {
    public let id = "fake.failing.v1"
    public let displayName = "必定失败（测试用）"

    private let message: String

    public init(message: String = "这是测试用的失败") {
        self.message = message
    }

    public func availability(source: Locale.Language?, target: Locale.Language) async -> TranslationAvailability {
        .unsupported
    }

    public func translate(
        segments: [TranslationSegment],
        sourceLanguage: Locale.Language?,
        targetLanguage: Locale.Language,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [TranslatedSegment] {
        throw TranslationEngineError.engineFailed(message)
    }
}
