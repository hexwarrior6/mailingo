import Foundation

/// 数一数邮件里引用了多少**外部**图片。
///
/// ## 为什么需要
///
/// 默认拦截外部图片是对的（远程图片是最常见的追踪手段），但用户看不到任何提示时，
/// 只会觉得"图裂了""emoji 少了"。真实案例：一封营销邮件把 emoji 做成了远程图片
/// （`<img alt="🌍" src="https://.../1f30d.png">`），于是拦截之后
/// 那几个 emoji 就凭空消失了 —— 而同封邮件里真正的文字 emoji（📅📍）还正常显示，
/// 表现成"有些 emoji 显示不出来"，非常难猜。
///
/// 有了这个计数，界面就能明说「已拦截 N 张外部图片」，并给出一键载入。
public enum RemoteContentScanner {

    /// 引用外部（http/https）图片的 `<img>` 数量。
    public static func remoteImageCount(in html: String) -> Int {
        remoteImageURLs(in: html).count
    }

    /// 邮件里全部外部图片的 src（文档顺序，去重）。
    ///
    /// 图片翻译的角标按这个清单铺：这些图要能被点「译」，就得先知道它们是谁。
    /// 注意 src 里的 HTML 实体（`&amp;` 等）**不在这里解码** —— 调用方按需处理，
    /// 因为改写回 HTML 时必须保持实体原样。
    public static func remoteImageURLs(in html: String) -> [String] {
        guard let tagRegex = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#) else { return [] }
        guard let srcRegex = try? NSRegularExpression(pattern: #"(?is)\bsrc\s*=\s*["']?\s*(https?://[^"'\s>]+)"#) else { return [] }

        let full = NSRange(html.startIndex..., in: html)
        var urls: [String] = []
        var seen = Set<String>()
        for match in tagRegex.matches(in: html, range: full) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let srcMatch = srcRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let valueRange = Range(srcMatch.range(at: 1), in: tag) else { continue }
            let url = String(tag[valueRange])
            if seen.insert(url).inserted { urls.append(url) }
        }
        return urls
    }
}
