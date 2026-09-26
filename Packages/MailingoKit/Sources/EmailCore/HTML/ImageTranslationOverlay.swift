import Foundation

/// 给邮件里的图片注入"图片翻译"角标（图右下角的小按钮）。
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
///
/// ## 覆盖哪些图
///
/// 两类图源都能注入：**内联图**（`src="mailingo-cid://…"`，键 = 解码后的
/// Content-ID）和**外部图**（`src="https://…"`，键 = 完整 URL）。
/// 外部图必须由用户放行远程内容后才会出现角标 —— 拦截中的图连图都看不见，
/// 更不该替用户去下载。
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

    /// 给图片注入角标。`badges` 按**图源键**索引（内联 = Content-ID，
    /// 外部 = URL）；**没有条目的图不加角标**，一个字节都不动。
    ///
    /// ## 为什么优先匹配「锚点包图」
    ///
    /// 营销邮件的图片几乎都是 `<a href="商品页"><img …></a>`。HTML **禁止
    /// 锚点嵌套**：往这样的图里塞角标 `<a>`，WebKit 解析时会强制拆开外层
    /// 锚点并重构 DOM —— 角标定位失效（乱飘）、同区域的后续兄弟节点
    /// （包括外部图片）整块丢失，实测踩坑。所以「锚点包图」必须整体包
    /// 装饰层，角标作为锚点的**兄弟**注入。
    public static func inject(into html: String, badges: [String: Badge]) -> String {
        guard !badges.isEmpty, html.lowercased().contains("<img") else { return html }

        // 先尝试「锚点包图」形态（组 1-2：锚点整体 / img），再尝试裸 img（组 3）
        // —— 一趟扫描，避免二次包装。src 的取值在 replacement 里再提取分类。
        let pattern = #"(?i)(<a\b[^>]*>\s*(<img\b[^>]*>)\s*</a>)|(<img\b[^>]*>)"#
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

    /// 从点击的自定义 scheme URL 里取回图源键。
    public static func actionID(from url: URL) -> String? {
        let prefix = "\(scheme)://"
        var raw = url.absoluteString
        guard raw.hasPrefix(prefix) else { return nil }

        raw = String(raw.dropFirst(prefix.count))
        if let query = raw.firstIndex(of: "?") { raw = String(raw[raw.startIndex..<query]) }
        guard !raw.isEmpty else { return nil }

        return raw.removingPercentEncoding ?? raw
    }

    /// 从译文图 scheme 的 URL 里取回图源键。
    public static func contentID(fromOutputURL url: URL) -> String? {
        let prefix = "\(outputScheme)://"
        var raw = url.absoluteString
        guard raw.hasPrefix(prefix) else { return nil }

        raw = String(raw.dropFirst(prefix.count))
        if let query = raw.firstIndex(of: "?") { raw = String(raw[raw.startIndex..<query]) }
        guard !raw.isEmpty else { return nil }

        return raw.removingPercentEncoding ?? raw
    }

    /// 生成角标的 href。键既可以是 Content-ID 也可以是外部 URL ——
    /// 一律做 percent-encoding（Content-ID 里有 `@`，URL 里有 `:?&`）。
    public static func actionURLString(forContentID cid: String) -> String {
        let encoded = cid.addingPercentEncoding(withAllowedCharacters: CIDReferenceRewriter.unreservedCharacters) ?? cid
        return "\(scheme)://\(encoded)"
    }

    /// 生成译文图的 src。键语义同上。
    public static func outputURLString(forKey key: String) -> String {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: CIDReferenceRewriter.unreservedCharacters) ?? key
        return "\(outputScheme)://\(encoded)"
    }

    // MARK: - 私有

    /// 从 img 标签里提取 src 的值（兼容双引号 / 单引号 / 无引号）。
    private static func srcValue(in imgTag: String) -> String? {
        let pattern = #"(?is)\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let match = regex.firstMatch(in: imgTag, range: NSRange(imgTag.startIndex..., in: imgTag)) else { return nil }
        for group in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: group), in: imgTag) {
                return String(imgTag[range])
            }
        }
        return nil
    }

    /// src 值 → 图源键。内联 = 解码后的 Content-ID；外部 = 完整 URL
    /// （HTML 实体解码，`&amp;` 一类不处理会让下载 404）。
    /// 其他形态（data:、相对路径…）返回 nil —— 不翻译。
    private static func badgeKey(forSrcValue value: String) -> String? {
        if value.hasPrefix("mailingo-cid://") {
            let raw = String(value.dropFirst("mailingo-cid://".count))
            return raw.removingPercentEncoding ?? raw
        }
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return HTMLEntities.decode(value)
        }
        return nil
    }

    private static func replacement(for match: NSTextCheckingResult, in html: String, badges: [String: Badge]) -> String {
        guard let fullRange = Range(match.range, in: html) else { return "" }

        // 组 1-2 =「锚点包图」：组 1（锚点整体）已包含组 2（img）
        if let anchorRange = Range(match.range(at: 1), in: html),
           let imgRange = Range(match.range(at: 2), in: html) {
            let anchorWithImg = String(html[anchorRange])
            let imgTag = String(html[imgRange])
            guard let srcValue = srcValue(in: imgTag),
                  let key = badgeKey(forSrcValue: srcValue),
                  let badge = badges[key] else { return anchorWithImg }

            // 已翻译时仅替换 img 的图源 scheme；其余字节原样保留
            let img = badge == .restore ? rewrittenSource(imgTag, srcValue: srcValue, key: key) : imgTag
            let inner = anchorWithImg.replacingOccurrences(of: imgTag, with: img)
            let button = badgeAnchor(key: key, badge: badge)
            // 角标是锚点的**兄弟**（不是嵌进锚点里），装饰层包住两者
            return #"<span style="\#(wrapperStyle)">\#(inner)\#(button)</span>"#
        }

        // 组 3 = 裸 img
        guard let imgRange = Range(match.range(at: 3), in: html) else {
            return String(html[fullRange])
        }
        let imgTag = String(html[imgRange])
        guard let srcValue = srcValue(in: imgTag),
              let key = badgeKey(forSrcValue: srcValue),
              let badge = badges[key] else { return imgTag }

        // 裸 img 但实际上包在**复杂锚点**里（img 外面还有其他标签）：
        // 注入角标会产生嵌套锚点破坏 DOM —— 宁可不加角标也不能弄坏邮件。
        // （简单形态 `<a><img></a>` 已被组 1-2 优先处理，不会走到这里。）
        let before = html.startIndex..<imgRange.lowerBound
        let lastOpen = html.range(of: "<a", options: .backwards, range: before)
        let lastClose = html.range(of: "</a", options: .backwards, range: before)
        let insideAnchor: Bool
        if let open = lastOpen {
            insideAnchor = lastClose.map { open.lowerBound > $0.lowerBound } ?? true
        } else {
            insideAnchor = false
        }
        if insideAnchor { return imgTag }

        let img = badge == .restore ? rewrittenSource(imgTag, srcValue: srcValue, key: key) : imgTag
        let button = badgeAnchor(key: key, badge: badge)
        return #"<span style="\#(wrapperStyle)">\#(img)\#(button)</span>"#
    }

    /// 已翻译时把 img 的图源换成译文 scheme —— URL 变化使 WebKit 缓存失效。
    /// 输出 URL 一律由**解码后的键**生成（原始 src 值可能带 HTML 实体），
    /// 这样渲染层取图时的键与结果字典完全一致。
    private static func rewrittenSource(_ imgTag: String, srcValue: String, key: String) -> String {
        imgTag.replacingOccurrences(of: srcValue, with: outputURLString(forKey: key))
    }

    /// 装饰层样式。`!important` 是必须的 —— 邮件自带的 CSS 会覆盖
    /// 注入元素的普通内联样式（reset 样式很常见）。
    private static let wrapperStyle =
        "position:relative!important;display:inline-block!important;line-height:0!important;"

    private static func badgeAnchor(key: String, badge: Badge) -> String {
        #"<a href="\#(actionURLString(forContentID: key))" style="position:absolute!important;right:6px!important;bottom:6px!important;display:inline-block!important;min-width:24px!important;height:24px!important;padding:0 7px!important;border-radius:12px!important;background:rgba(20,20,20,0.55)!important;color:#fff!important;font:600 12px/24px -apple-system,'Helvetica Neue',sans-serif!important;text-align:center!important;text-decoration:none!important;-webkit-user-select:none!important;">\#(badge.label)</a>"#
    }
}
