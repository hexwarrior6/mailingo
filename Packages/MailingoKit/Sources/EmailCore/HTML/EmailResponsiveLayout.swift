import Foundation

/// 为邮件 HTML 注入响应式排版样式，解决窄屏/半屏宽度下的水平滚动与图片截断问题。
///
/// 保留发件人的容器最大宽度、列宽比例、并列布局和媒体查询。
/// 固定宽度表格改用 min(100%, 原宽度)，只在空间不足时收缩；
/// 完整声明了列宽的单行表格按原比例收缩，不让每个活动独立争抢宽度。
/// 不再全局清除单元格宽度或把所有容器拉伸到窗口宽度。
///
/// ## 只作用于渲染副本
///
/// 与 `CIDReferenceRewriter` 一致，此注入**仅作用于 WKWebView 呈现前的临时 HTML**，
/// 绝不写回邮件缓存或破坏 MIME 保真度。
public enum EmailResponsiveLayout {

    /// 注入的样式标识。
    public static let styleID = "mailingo-responsive-layout"

    /// 响应式布局 CSS 规则。
    ///
    /// 注意：为什么横向防溢出使用 `overflow-x: clip !important;` 并显式声明 `body { overflow-y: visible !important; }`：
    /// 如果在 `body` 上写 `overflow-x: hidden`，CSS 规范会强制将 `overflow-y` 自动计算为 `auto`，
    /// 导致 `body` 本身成为一个独立的滚动容器，在 WebKit 中渲染出第二条紧贴内容边缘的垂直滚动条（双滚动条）。
    /// 使用 `clip` 既能硬性裁切横向溢出，又不会触发新的滚动容器，彻底杜绝双滚动条。
    public static let css: String = """
    html {
        max-width: 100% !important;
        overflow-x: clip !important;
        -webkit-text-size-adjust: 100% !important;
    }
    body {
        max-width: 100% !important;
        overflow-x: clip !important;
        overflow-y: visible !important;
        -webkit-text-size-adjust: 100% !important;
        word-wrap: break-word !important;
        overflow-wrap: anywhere !important;
    }
    table {
        max-width: 100% !important;
    }
    /* 独立签名表不应让后文环绕；同一单元格中的并列布局表保留原有浮动。 */
    table[align="left"]:not(td table), table[align="right"]:not(td table),
    td > table[align="left"]:only-of-type, td > table[align="right"]:only-of-type {
        float: none !important;
    }
    td, th {
        max-width: 100% !important;
    }
    /* 落款签名区域保护：右边框分隔线所在图片列保持合适宽度 */
    td[style*="border-right"]:has(img) {
        min-width: 140px !important;
    }
    /* 小图标（社媒图标、小徽标 <= 48px）：保留自身尺寸，不缩为 0 也不撑大所在单元格 */
    img[width="16"], img[width="18"], img[width="20"], img[width="24"],
    img[width="26"], img[width="28"], img[width="30"], img[width="32"],
    img[width="36"], img[width="40"], img[width="48"] {
        max-width: none !important;
        height: auto !important;
        flex-shrink: 0 !important;
    }
    /* 仅对叶子 td 或段落限制 nowrap，绝不匹配外层大容器 td（防止正文长段落无法折行） */
    td:not(:has(table)):has(img[width="16"]),
    td:not(:has(table)):has(img[width="18"]),
    td:not(:has(table)):has(img[width="20"]),
    td:not(:has(table)):has(img[width="24"]),
    td:not(:has(table)):has(img[width="26"]),
    td:not(:has(table)):has(img[width="28"]),
    td:not(:has(table)):has(img[width="30"]),
    td:not(:has(table)):has(img[width="32"]),
    p:has(img[width="16"]),
    p:has(img[width="20"]),
    p:has(img[width="24"]),
    p:has(img[width="26"]),
    p:has(img[width="30"]),
    p:has(img[width="32"]) {
        white-space: nowrap !important;
    }
    /* 多图标签名单元格保留至少 90px，防止并排溢出覆盖相邻列 */
    td:not(:has(table)):has(img[width="26"]) {
        min-width: 90px !important;
    }
    div, section, article {
        max-width: 100% !important;
    }
    hr {
        clear: both !important;
    }
    pre {
        max-width: 100% !important;
        overflow-x: auto !important;
        white-space: pre-wrap !important;
        word-break: break-all !important;
    }
    img, video, canvas {
        max-width: 100% !important;
        height: auto !important;
    }
    svg {
        max-width: 100% !important;
    }
    """

    /// 完整的 `<style>` 标签。
    public static var styleTag: String {
        "<style id=\"\(styleID)\">\n\(css)\n</style>"
    }

    /// 将响应式样式注入到 HTML 字符串中。
    ///
    /// 注入优先顺序：
    /// 1. 若已包含 `id="mailingo-responsive-layout"`，原样返回（幂等）；
    /// 2. 若存在 `</head>`，插入到 `</head>` 之前（确保在邮件原有样式之后生效）；
    /// 3. 若存在 `<head...>`，插入到 `<head...>` 之后；
    /// 4. 若存在 `<body...>`，插入到 `<body...>` 之后；
    /// 5. 否则作为前缀拼接到 HTML 最前面。
    public static func inject(into html: String) -> String {
        guard !html.contains("id=\"\(styleID)\"") else { return html }
        let html = EmailTableColumnLayout.preservingColumnRatios(in: html)

        // 1. </head> 之前
        if let headCloseRange = html.range(of: "</head>", options: .caseInsensitive) {
            var out = html
            out.insert(contentsOf: styleTag, at: headCloseRange.lowerBound)
            return out
        }

        // 2. <head...> 之后
        if let headOpenRegex = try? NSRegularExpression(pattern: #"(?i)<head\b[^>]*>"#),
           let match = headOpenRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(match.range, in: html) {
            var out = html
            out.insert(contentsOf: styleTag, at: r.upperBound)
            return out
        }

        // 3. <body...> 之后
        if let bodyOpenRegex = try? NSRegularExpression(pattern: #"(?i)<body\b[^>]*>"#),
           let match = bodyOpenRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(match.range, in: html) {
            var out = html
            out.insert(contentsOf: styleTag, at: r.upperBound)
            return out
        }

        // 4. HTML 片段前缀
        return styleTag + html
    }
}
