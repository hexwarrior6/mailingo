import Foundation

// MARK: - MIME

/// 解码后的一封邮件。
public struct DecodedEmail: Sendable {
    /// 优先选用的 `text/html` 正文（已按 charset 解码为 String）。
    public var html: String?
    /// `text/plain` 正文，作为 HTML 缺失时的回退。
    public var plainText: String?
    /// 内联资源（`Content-ID` → 字节），用于渲染 `cid:` 图片。
    public var inlineResources: [String: InlineResource]
    /// MIME 结构的文字描述，用于在 UI 里展示"这封信长什么样"。
    public var structureSummary: [String]

    public init(
        html: String? = nil,
        plainText: String? = nil,
        inlineResources: [String: InlineResource] = [:],
        structureSummary: [String] = []
    ) {
        self.html = html
        self.plainText = plainText
        self.inlineResources = inlineResources
        self.structureSummary = structureSummary
    }
}

/// 一个内联 MIME 部分（通常是 `cid:` 引用的图片）。
public struct InlineResource: Sendable {
    public var contentID: String
    public var mimeType: String
    public var data: Data

    public init(contentID: String, mimeType: String, data: Data) {
        self.contentID = contentID
        self.mimeType = mimeType
        self.data = data
    }
}

/// MIME 解码的抽象。V1 用自研精简实现；
/// 将来若要换 SwiftMail 等第三方解析器，只需另写一个实现（见方案 §11 D3）。
public protocol MIMEDecoding: Sendable {
    func decode(_ rawMessage: Data) throws -> DecodedEmail
}

public enum MIMEDecodingError: Error, CustomStringConvertible {
    case emptyMessage
    case malformedHeaders

    public var description: String {
        switch self {
        case .emptyMessage: "邮件内容为空"
        case .malformedHeaders: "头部格式无法解析（缺少头部/正文分隔空行）"
        }
    }
}

// MARK: - 翻译分段

/// 一个待翻译的文本片段。
///
/// 注意 `range` 指向的是**原始 HTML 字符串**里的位置 —— 这是"字节偏移切片"方案的核心：
/// 我们只替换这个区间，其余字节原样保留（见方案 §4.4）。
public struct TranslationSegment: Sendable, Identifiable {
    public let id: Int
    public let kind: SegmentKind
    /// 已做实体解码的正文（不含前后空白）。
    public let sourceText: String
    /// 该文本节点在原始 HTML 中的完整区间。
    public let range: Range<String.Index>
    /// 去掉前后空白后、真正要替换的区间。
    public let coreRange: Range<String.Index>
    /// 上下文里的祖先标签名（由内到外），供将来给 LLM 提供语境。
    public let ancestorTags: [String]
    /// 最近的块级祖先标签。同一段落里的片段靠它归组。
    public let blockAncestor: String?
    /// 是否是「被行内标签切开的孤立虚词」。
    ///
    /// 典型来源：`<b>9:00</b> to <b>11:00</b>` 里的 `to`、
    /// `14<sup>th</sup>` 里的 `th`。这类片段脱离上下文就没法翻对。
    ///
    /// 注意：**是否跳过它由引擎决定** —— 拿到完整上下文的 LLM 能翻对，
    /// 而 Apple 翻译的接口只收一段文本、看不到上下文，所以要跳过。
    /// 见 `TranslationEngine.hasFullContext`。
    public let isContextlessOrphan: Bool

    public init(
        id: Int,
        kind: SegmentKind,
        sourceText: String,
        range: Range<String.Index>,
        coreRange: Range<String.Index>,
        ancestorTags: [String],
        blockAncestor: String? = nil,
        isContextlessOrphan: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.sourceText = sourceText
        self.range = range
        self.coreRange = coreRange
        self.ancestorTags = ancestorTags
        self.blockAncestor = blockAncestor
        self.isContextlessOrphan = isContextlessOrphan
    }
}

/// 片段的语义类型。将来接 LLM 时可用来提示语气（按钮短、正文长）。
public enum SegmentKind: String, Sendable, CaseIterable {
    case heading
    case paragraph
    case link
    case button
    case tableCell
    case listItem
    case text

    /// 由祖先标签栈推断类型。
    static func infer(from tags: [String]) -> SegmentKind {
        // 从最内层往外找第一个能定性的标签
        for tag in tags.reversed() {
            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6": return .heading
            case "a": return .link
            case "button": return .button
            case "td", "th": return .tableCell
            case "li": return .listItem
            case "p": return .paragraph
            default: continue
            }
        }
        return .text
    }
}

/// 翻译结果。引擎只回文本，不改结构。
public struct TranslatedSegment: Sendable, Identifiable {
    public let id: Int
    public let targetText: String

    public init(id: Int, targetText: String) {
        self.id = id
        self.targetText = targetText
    }
}

// MARK: - 翻译引擎

/// 语言对是否可用。
///
/// `.supported` 与 `.installed` 的区别很关键：前者代表系统支持这个语言对、
/// 但**语言包还没下载**，首次翻译会触发系统下载。UI 要能区分「能翻」和
/// 「要先下语言包」，否则用户会以为卡住了。
public enum TranslationAvailability: Sendable, Equatable {
    case installed
    case supported
    case unsupported

    public var canTranslate: Bool {
        self != .unsupported
    }
}

public enum TranslationEngineError: Error, CustomStringConvertible {
    case unsupportedLanguagePair(source: String?, target: String)
    case cannotIdentifyLanguage
    case sessionUnavailable(String)
    case engineFailed(String)

    public var description: String {
        switch self {
        case .unsupportedLanguagePair(let source, let target):
            "不支持的语言对：\(source ?? "自动检测") → \(target)"
        case .cannotIdentifyLanguage:
            "无法识别源语言"
        case .sessionUnavailable(let detail):
            "翻译会话不可用：\(detail)"
        case .engineFailed(let detail):
            "翻译失败：\(detail)"
        }
    }
}

/// 翻译层抽象（方案 §7）。UI 不直接依赖具体引擎。
public protocol TranslationEngine: Sendable {
    /// 进缓存 key 的命名空间，换引擎即自动失效旧缓存。
    var id: String { get }
    var displayName: String { get }

    /// 引擎是否拿得到**完整语境**。
    ///
    /// - Apple 翻译的接口只接受"要翻的这段文本"，看不到上下文 → `false`。
    ///   于是像 ` to `、`th` 这种被行内标签切开的孤立虚词会被管线**剔出去、
    ///   保留原文** —— 翻错比不翻更糟。
    /// - LLM 引擎可以把整封邮件的文本作为输入一起给它 → `true`，
    ///   这类片段由模型自己看着上下文翻。
    var hasFullContext: Bool { get }

    /// 查询语言对可用性。`source` 为 nil 表示交给引擎自动检测。
    func availability(source: Locale.Language?, target: Locale.Language) async -> TranslationAvailability

    /// 批量翻译。
    ///
    /// 契约：
    /// - 返回的 `TranslatedSegment.id` 必须与入参一一对应 —— **不要依赖数组顺序**，
    ///   将来接 LLM 的引擎不保证保序，按 id 对账才安全。
    /// - `progress(已完成, 总数)` 会被多次调用，用于流式 UI；允许在任意线程调用。
    /// - 抛错时调用方视为整批失败，不做部分提交。
    func translate(
        segments: [TranslationSegment],
        sourceLanguage: Locale.Language?,
        targetLanguage: Locale.Language,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async throws -> [TranslatedSegment]
}

extension TranslationEngine {
    /// 默认认为引擎看不到上下文（保守：宁可少翻，不要翻错）。
    public var hasFullContext: Bool { false }

    /// 不需要进度的调用方用这个。
    public func translate(
        segments: [TranslationSegment],
        sourceLanguage: Locale.Language?,
        targetLanguage: Locale.Language
    ) async throws -> [TranslatedSegment] {
        try await translate(
            segments: segments,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            progress: { _, _ in }
        )
    }
}

// MARK: - 巡检结果

/// `EmailInspector` 的产物：一次把「邮件结构 + 提取出的片段 + 切片后的 HTML」都算出来。
/// 这是 M3 阶段在 App 里展示的东西。
public struct EmailInspection: Sendable {
    public var decoded: DecodedEmail
    /// 原始 HTML（或由纯文本合成的 HTML）。
    public var originalHTML: String
    /// 是否走了纯文本回退路径（原本没有 text/html 部分）。
    public var usedPlainTextFallback: Bool
    public var segments: [TranslationSegment]
    /// 用假翻译切片后的 HTML —— 用来肉眼验证"只有文字变了"。
    public var splicedHTML: String
    /// 保真自检：非文本字节是否与原文完全一致。
    public var fidelity: FidelityReport

    public init(
        decoded: DecodedEmail,
        originalHTML: String,
        usedPlainTextFallback: Bool,
        segments: [TranslationSegment],
        splicedHTML: String,
        fidelity: FidelityReport
    ) {
        self.decoded = decoded
        self.originalHTML = originalHTML
        self.usedPlainTextFallback = usedPlainTextFallback
        self.segments = segments
        self.splicedHTML = splicedHTML
        self.fidelity = fidelity
    }
}

/// 保真自检结果。这是 §6 测试策略里那条强断言的运行时版本。
public struct FidelityReport: Sendable {
    public var nonTextBytesIdentical: Bool
    public var tagSequenceIdentical: Bool
    public var changedSegmentCount: Int
    public var detail: String

    public init(
        nonTextBytesIdentical: Bool,
        tagSequenceIdentical: Bool,
        changedSegmentCount: Int,
        detail: String
    ) {
        self.nonTextBytesIdentical = nonTextBytesIdentical
        self.tagSequenceIdentical = tagSequenceIdentical
        self.changedSegmentCount = changedSegmentCount
        self.detail = detail
    }
}
