import Foundation

/// 把 HTML 里的 `cid:` 引用改写成自定义 URL scheme。
///
/// ## 为什么需要
///
/// 邮件里的内嵌图片（签名 logo、商品图、图标）在 HTML 里写的是
/// `<img src="cid:logo@example">` —— `cid` 是 MIME 的 `Content-ID`。
/// 浏览器不知道 `cid:` 是什么协议，**这些图会完全显示不出来**。
///
/// 做法：渲染前把 `cid:xxx` 改写成 `mailingo-cid://xxx`，再用
/// `WKURLSchemeHandler` 接住这个 scheme，从解码好的 MIME 部分里取字节返回。
///
/// ## 只作用于渲染副本
///
/// 这个改写**不写回缓存/译文 HTML** —— 缓存里始终保持原样，
/// 保真断言（非文本字节一致）也照旧成立。渲染前临时改一份即可。
public enum CIDReferenceRewriter {

    /// 自定义 scheme。用连字符而不是下划线，避免踩 URL 解析的坑。
    public static let scheme = "mailingo-cid"

    /// 把 `src` / `background` 里的 `cid:` 改写成自定义 scheme。
    ///
    /// 只动这两个属性里的值，**其余字节一个不碰** —— 和切片管线一个原则。
    public static func rewrite(_ html: String) -> String {
        guard html.range(of: "cid:", options: .caseInsensitive) != nil else { return html }

        let pattern = #"(?i)\b(src|background)\s*=\s*(?:"cid:([^"]*)"|'cid:([^']*)'|cid:([^\s>"']+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard !matches.isEmpty else { return html }

        var out = ""
        out.reserveCapacity(html.count)
        var cursor = html.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: html) else { continue }
            out += html[cursor..<fullRange.lowerBound]
            out += replacement(for: match, in: html)
            cursor = fullRange.upperBound
        }
        out += html[cursor...]

        return out
    }

    /// 从自定义 scheme 的 URL 里取回 Content-ID。
    public static func contentID(from url: URL) -> String? {
        let prefix = "\(scheme)://"
        var raw = url.absoluteString
        guard raw.hasPrefix(prefix) else { return nil }

        raw = String(raw.dropFirst(prefix.count))
        // 去掉可能存在的尾部斜杠或片段
        if let hash = raw.firstIndex(of: "#") { raw = String(raw[raw.startIndex..<hash]) }
        guard !raw.isEmpty else { return nil }

        return raw.removingPercentEncoding ?? raw
    }

    /// URL 里的**非保留字符**（RFC 3986 unreserved）。
    ///
    /// 用这个集合而不是 `.alphanumerics`：后者会把 `-` `.` `_` `~` 也编码掉，
    /// 虽然合法但把 URL 弄得很难看（`pic-1` 变成 `pic%2D1`），也没必要。
    /// `ImageTranslationOverlay` 的角标 href 也用同一套编码，保证可互相解析。
    public static let unreservedCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-._~"))

    /// 生成自定义 scheme 的 URL 字符串。
    public static func urlString(forContentID cid: String) -> String {
        // Content-ID 里经常有 `@`、`/`、`?` 这类必须编码的字符
        let encoded = cid.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? cid
        return "\(scheme)://\(encoded)"
    }

    // MARK: - 私有

    private static func replacement(for match: NSTextCheckingResult, in html: String) -> String {
        guard let attributeRange = Range(match.range(at: 1), in: html) else { return "" }
        let attribute = html[attributeRange]

        // 捕获组编号：1 = 属性名，2/3/4 = 双引号 / 单引号 / 无引号的 Content-ID。
        //
        // ⚠️ 这里踩过坑：外层那一组写成 `(?:` 是**非捕获**组，
        // 所以 cid 落在 2/3/4 而不是 3/4/5。之前从 3 开始找，
        // 恰好漏掉最常见的双引号分支（`src="cid:xxx"` 完全改不动）。
        // 上界用 numberOfRanges，别硬编码 —— 未参与匹配的分组不保证有条目。
        var cid: String?
        for group in 2..<match.numberOfRanges {
            if let range = Range(match.range(at: group), in: html) {
                cid = String(html[range])
                break
            }
        }

        guard let cid, !cid.isEmpty else {
            // 解析不出 Content-ID 就原样保留，别把属性删掉
            guard let fullRange = Range(match.range, in: html) else { return "" }
            return String(html[fullRange])
        }

        return #"\#(attribute)="\#(urlString(forContentID: cid))""#
    }
}
