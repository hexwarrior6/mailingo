import Foundation

/// 给内联图片注入"图片翻译"角标（图右下角的小按钮）。
///
/// ## 只作用于渲染副本
///
/// 和 `CIDReferenceRewriter` 同一个原则：注入**只发生在渲染前的临时副本上**，
/// 缓存与保真断言的 HTML 永远保持原样 —— 新增节点会破坏
/// 「非文本字节一致 / 标签序列一致」两条强断言，所以绝不能进切片管线。
///
/// ## 为什么按钮是 <a> 而不是真正的按钮
///
/// 邮件渲染的 WKWebView **禁用了 JavaScript**（脚本防护），任何基于
/// script 的交互都不存在。`<a href="mailingo-imgtrans://…">` 是唯一
/// 无需 JS 的点击通道 —— 由 `WKNavigationDelegate` 拦下这个 scheme。
public enum ImageTranslationOverlay {

    public static let scheme = "mailingo-imgtrans"

    /// 译文图的图源 scheme。翻译完成后原图的 `src` 会被改写成这个 scheme ——
    /// **URL 必须变化**：WKWebView 会缓存自定义 scheme 的响应，同 URL 重载
    /// 拿到的还是缓存的原图字节（实测踩过），换 scheme 才能强制重新取图。
    public static let outputScheme = "mailingo-imgout"

    /// 角标形态。由 App 层根据每张图的状态映射而来。
    public enum Badge {
        /// 未翻译：点它开始翻译
        case translate
        /// 翻译中
        case busy
        /// 已翻译（图已是渲染译文）：点它切回原图
        case restore

        var label: String {
            switch self {
            case .translate: "译"
            case .busy: "…"
            case .restore: "原"
            }
        }
    }

    /// 给内联图片（`<img src="mailingo-cid://…">`）注入角标。
    ///
    /// `badges` 按 Content-ID 索引；**没有条目的图不加角标**
    /// （比如没配置图片翻译服务、或这张图不在可翻译范围里）。
    public static func inject(into html: String, badges: [String: Badge]) -> String {
        guard !badges.isEmpty, html.contains(CIDReferenceRewriter.scheme) else { return html }

        let pattern = #"(?i)<img\b[^>]*\bsrc="mailingo-cid://([^"]*)"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard !matches.isEmpty else { return html }

        var out = ""
        out.reserveCapacity(html.count + matches.count * 300)
        var cursor = html.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: html) else { continue }
            out += html[cursor..<fullRange.lowerBound]
            out += replacement(for: match, in: html, badges: badges)
            cursor = fullRange.upperBound
        }
        out += html[cursor...]

        return out
    }

    /// 从点击的自定义 scheme URL 里取回 Content-ID。
    public static func actionID(from url: URL) -> String? {
        let prefix = "\(scheme)://"
        var raw = url.absoluteString
        guard raw.hasPrefix(prefix) else { return nil }

        raw = String(raw.dropFirst(prefix.count))
        if let query = raw.firstIndex(of: "?") { raw = String(raw[raw.startIndex..<query]) }
        guard !raw.isEmpty else { return nil }

        return raw.removingPercentEncoding ?? raw
    }

    /// 从译文图 scheme 的 URL 里取回 Content-ID。
    public static func contentID(fromOutputURL url: URL) -> String? {
        let prefix = "\(outputScheme)://"
        var raw = url.absoluteString
        guard raw.hasPrefix(prefix) else { return nil }

        raw = String(raw.dropFirst(prefix.count))
        if let query = raw.firstIndex(of: "?") { raw = String(raw[raw.startIndex..<query]) }
        guard !raw.isEmpty else { return nil }

        return raw.removingPercentEncoding ?? raw
    }

    /// 生成角标的 href。
    static func actionURLString(forContentID cid: String) -> String {
        let encoded = cid.addingPercentEncoding(withAllowedCharacters: CIDReferenceRewriter.unreservedCharacters) ?? cid
        return "\(scheme)://\(encoded)"
    }

    // MARK: - 私有

    private static func replacement(for match: NSTextCheckingResult, in html: String, badges: [String: Badge]) -> String {
        guard let fullRange = Range(match.range, in: html) else { return "" }
        var imgTag = String(html[fullRange])

        // 捕获组 1 = src 属性里 percent-encoded 的 Content-ID
        guard let cidRange = Range(match.range(at: 1), in: html),
              let cid = html[cidRange].removingPercentEncoding,
              let badge = badges[cid] else {
            return imgTag
        }

        // 已翻译：图源换成译文 scheme —— URL 变了，WebKit 缓存失效，必然重新取图
        if badge == .restore {
            imgTag = imgTag.replacingOccurrences(
                of: "\(CIDReferenceRewriter.scheme)://",
                with: "\(outputScheme)://"
            )
        }

        let button = """
        <a href="\(actionURLString(forContentID: cid))" style="position:absolute;right:6px;bottom:6px;display:inline-block;min-width:24px;height:24px;padding:0 7px;border-radius:12px;background:rgba(20,20,20,0.55);color:#fff;font:600 12px/24px -apple-system,'Helvetica Neue',sans-serif;text-align:center;text-decoration:none;-webkit-user-select:none;">\(badge.label)</a>
        """
        return #"<span style="position:relative;display:inline-block;line-height:0;">\#(imgTag)\#(button)</span>"#
    }
}
