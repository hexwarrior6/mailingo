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
/// ## 为什么不能只写 `img { max-width: 100%; }`
///
/// WebKit 的表格布局算法在遇到具有固定属性（如 `<table width="600">` 或 `<table style="width:600px">`）
/// 时，单纯的 `table { max-width: 100% !important; }` 不会收缩表格！
/// 必须配合针对非百分比宽度的 `width: auto !important; max-width: 100% !important;`，
/// 才能使固定宽度表格自适应窄屏，同时避免破坏按百分比排版的列（如 `width="50%"`）或拉伸小按钮（如 `width="120"`）。
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
    table[width]:not([width$="%"]) {
        width: auto !important;
        max-width: 100% !important;
    }
    table[style*="width"]:not([style*="%"]) {
        width: auto !important;
        max-width: 100% !important;
    }
    td, th {
        max-width: 100% !important;
    }
    div, section, article {
        max-width: 100% !important;
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
