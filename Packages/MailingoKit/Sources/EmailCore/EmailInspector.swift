import Foundation

/// 解码 + 提取分段的结果（还没翻译）。
public struct EmailAnalysis: Sendable {
    public var decoded: DecodedEmail
    /// 用来分段的 HTML：优先 `text/html`，否则由 `text/plain` 合成。
    public var originalHTML: String
    /// 是否走了纯文本回退路径。
    public var usedPlainTextFallback: Bool
    public var segments: [TranslationSegment]

    public init(
        decoded: DecodedEmail,
        originalHTML: String,
        usedPlainTextFallback: Bool,
        segments: [TranslationSegment]
    ) {
        self.decoded = decoded
        self.originalHTML = originalHTML
        self.usedPlainTextFallback = usedPlainTextFallback
        self.segments = segments
    }
}

/// M3 的主入口：把一段原始 MIME 变成「结构 + 分段 + 切片结果 + 保真报告」。
///
/// 刻意拆成 analyze / apply 两步：
/// 翻译是异步的、可能需要用户授权的，而解析和切片都是纯函数。
/// 这样测试可以完全不碰翻译引擎。
public enum EmailInspector {

    /// 解码 MIME 并提取待翻译片段。纯同步、无副作用。
    ///
    /// ## 取消
    ///
    /// 调用方（App 的 `InspectorModel`）会在快速切邮件时取消这个任务：旧的
    /// 那封没必要再解析完。这里放两处 `checkCancellation` —— 把最长的两步
    /// （MIME 解码、HTML 分词）拆开，取消能在两步之间生效，省掉后面那一步。
    ///
    /// 之所以只放两处而不往分词器内部埋：这两个函数是纯函数，往里传"取消检查"
    /// 会把并发概念漏进 M3 的核心逻辑里。两步之间的粒度已经够用 ——
    /// 单封邮件这两步各自也就几十到几百毫秒。
    public static func analyze(
        rawMessage: Data,
        decoder: MIMEDecoding = RFC822MIMEDecoder()
    ) throws -> EmailAnalysis {
        try Task.checkCancellation()
        let decoded = try decoder.decode(rawMessage)

        let (html, usedFallback): (String, Bool)
        if let htmlBody = decoded.html, !htmlBody.isEmpty {
            (html, usedFallback) = (htmlBody, false)
        } else if let plain = decoded.plainText, !plain.isEmpty {
            (html, usedFallback) = (plainTextToHTML(plain), true)
        } else {
            (html, usedFallback) = ("", false)
        }

        try Task.checkCancellation()
        return EmailAnalysis(
            decoded: decoded,
            originalHTML: html,
            usedPlainTextFallback: usedFallback,
            segments: try SegmentExtractor.extract(from: html)
        )
    }

    /// 把译文写回，并做保真自检。
    /// - Throws: `CancellationError` —— 切片本身很便宜（实测 287 KB 只要
    ///   0.3 ms），但保真自检要分词，那才是大头。调用方不再需要结果时会
    ///   取消这个任务，抛出去让上层丢弃即可。
    public static func apply(
        translations: [Int: String],
        to analysis: EmailAnalysis
    ) throws -> EmailInspection {
        let spliced = HTMLSplicer.splice(
            html: analysis.originalHTML,
            segments: analysis.segments,
            translations: translations
        )
        return EmailInspection(
            decoded: analysis.decoded,
            originalHTML: analysis.originalHTML,
            usedPlainTextFallback: analysis.usedPlainTextFallback,
            segments: analysis.segments,
            splicedHTML: spliced,
            fidelity: try HTMLSplicer.verifyFidelity(
                original: analysis.originalHTML,
                spliced: spliced
            )
        )
    }

    // MARK: - 纯文本回退

    /// 只有 `text/plain` 的邮件也要能翻译，所以合成一份结构简单的 HTML。
    /// 按空行切段，段内换行转 `<br>`，这样每段是一个独立的翻译单元
    /// （而不是整封邮件变成一个巨大的片段）。
    static func plainTextToHTML(_ plain: String) -> String {
        let escapedParagraphs = plain
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { paragraph -> String in
                let escaped = HTMLEntities.escapeText(paragraph)
                return "<p>" + escaped.replacingOccurrences(of: "\n", with: "<br>") + "</p>"
            }
            .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family: -apple-system, sans-serif; font-size: 14px; line-height: 1.5; padding: 16px;">
        \(escapedParagraphs)
        </body></html>
        """
    }
}
