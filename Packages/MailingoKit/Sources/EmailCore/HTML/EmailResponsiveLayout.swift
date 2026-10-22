import Foundation

/// 为邮件 HTML 注入响应式排版样式，解决窄屏/半屏宽度下的水平滚动与图片截断问题。
///
/// ## 背景与机制
///
/// 传统排版与营销邮件大多基于桌面端固定宽度（常见 600px–800px）设计，使用固定宽度的 `<table>`
/// 或固定宽度 `<img>`。在分栏双语对比视图或分屏宽度下（约 350px–450px），
/// 固定宽度会导致：
/// 1. 出现全局水平滚动条，内容被裁切；
/// 2. 大图只显示一半，影响阅读体验。
///
/// ## 表格与正文排版机制
///
/// 传统排版与营销邮件大多基于固定宽度（常见 600px–800px）设计。在分栏双语对比视图或分屏宽度下（约 350px–450px）：
/// 1. 若仅对 `table` 应用 `max-width: 100%`，WebKit 的表格自动布局算法在遇到具有固定属性（如 `<td width="753">`
///    或 `<table style="max-width: 480pt">`）时，不会自动缩小外层容器，导致邮件正文长段落按 700px+ 宽度排版，
///    文字被右边缘硬性裁切截断。
/// 2. 为此，必须对声明了固定宽度或最大宽度的容器表格施加 `width: 100% !important; max-width: 100% !important;`，
///    确保邮件正文与卡片自适应窗口宽度，段落自然折行。
/// 3. 与此同时，邮件落款与签名常采用多列横向 `<table>`（例如左列放置组织 Logo，右列放置文字及社媒图标）。
///    当表格在窄屏收缩时，为防止 WebKit 将图片列过度压缩至仅剩数十像素，需通过 `:has()` 规则为带有非微缩图标
///    的图片列保留合理的 `min-width: 120px`，确保落款 Logo 清晰保真，社媒图标水平排布不折行。
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
    }
    table {
        max-width: 100% !important;
    }
    /* 取消表格默认浮动：Outlook 签名常带 align="left" (对应 float:left)，在响应式收缩后会导致后续保密声明横向环绕爬上右侧 */
    table[align="left"], table[align="right"] {
        float: none !important;
    }
    table[width]:not([width$="%"]),
    table[style*="width"]:not([style*="%"]),
    table[style*="max-width"] {
        width: auto !important;
        max-width: 100% !important;
    }
    body > table,
    body > div > table,
    div.WordSection1 > table,
    div.WordSection1 > div > table,
    div[align="center"] > table[style*="width"],
    div[align="center"] > table[style*="max-width"] {
        width: 100% !important;
    }
    td, th {
        max-width: 100% !important;
    }
    td[width]:not([width$="%"]),
    td[style*="width"]:not([style*="%"]) {
        width: auto !important;
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
