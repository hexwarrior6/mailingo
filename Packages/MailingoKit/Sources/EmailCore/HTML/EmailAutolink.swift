import Foundation

/// 自动把邮件正文里的纯文本 URL 和邮箱地址改写为可点击的超链接。
///
/// ## 为什么需要
///
/// 发件人经常直接把链接粘贴在邮件正文里（例如问卷链接、会议链接、注册地址），
/// 而没有为其显式添加 `<a href="...">` 超链接标签（甚至用颜色和下划线手动排版为链接外观）。
/// 在 Apple Mail 等原生客户端中，系统 Data Detectors 会自动将其识别为可点击链接；
/// 但在 WebKit 的 WKWebView 中，这些纯文本不会被自动链接化，导致用户无法点击。
///
/// ## 只作用于渲染副本
///
/// 与 `CIDReferenceRewriter` 和 `EmailResponsiveLayout` 一致，
/// 此改写**仅作用于 WKWebView 呈现前的临时 HTML**，
/// 绝不写回邮件缓存或破坏 MIME / 翻译管线的保真度。
public enum EmailAutolink {

    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// 将 HTML 文本节点中的纯文本链接自动包装为 `<a href="...">`。
    ///
    /// - 仅处理正文文本节点，严禁修改已有 `<a>`、`<button>`、`<head>`、`<select>` 等标签内部的文本。
    /// - 属性值、标签结构、注释与样式脚本 100% 保持不变。
    /// - 保证幂等：对已包含链接的 HTML 再次调用不会造成嵌套 `<a>`。
    public static func linkify(_ html: String) -> String {
        guard !html.isEmpty else { return html }
        guard html.contains(".") || html.contains("@") else { return html }
        guard let detector = detector else { return html }

        guard let runs = try? HTMLTokenizer.textRuns(in: html), !runs.isEmpty else {
            return html
        }

        var out = ""
        out.reserveCapacity(html.count + 256)
        var cursor = html.startIndex
        var hasModifications = false

        for run in runs {
            // 已在超链接或交互式元素内部：绝对不能嵌套 <a>
            if run.ancestorTags.contains("a") ||
               run.ancestorTags.contains("button") ||
               run.ancestorTags.contains("head") ||
               run.ancestorTags.contains("select") ||
               run.ancestorTags.contains("option") {
                continue
            }

            let runText = String(html[run.range])
            guard runText.contains(".") || runText.contains("@") else {
                continue
            }

            let matches = detector.matches(in: runText, range: NSRange(runText.startIndex..., in: runText))
            guard !matches.isEmpty else { continue }

            hasModifications = true
            out += html[cursor..<run.range.lowerBound]

            var runCursor = runText.startIndex
            for match in matches {
                guard let matchRange = Range(match.range, in: runText),
                      let targetURL = match.url else { continue }

                out += runText[runCursor..<matchRange.lowerBound]

                let matchedText = String(runText[matchRange])
                let rawURL = targetURL.absoluteString
                let decodedURL = HTMLEntities.decode(rawURL)
                let href = escapeAttribute(decodedURL)

                out += "<a href=\"\(href)\">\(matchedText)</a>"
                runCursor = matchRange.upperBound
            }
            out += runText[runCursor...]
            cursor = run.range.upperBound
        }

        guard hasModifications else { return html }
        out += html[cursor...]
        return out
    }

    private static func escapeAttribute(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": result += "&amp;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(ch)
            }
        }
        return result
    }
}
