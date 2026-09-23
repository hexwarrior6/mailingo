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
        guard let tagRegex = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#) else { return 0 }
        guard let srcRegex = try? NSRegularExpression(pattern: #"(?is)\bsrc\s*=\s*["']?\s*https?://"#) else { return 0 }

        let full = NSRange(html.startIndex..., in: html)
        return tagRegex.matches(in: html, range: full).reduce(into: 0) { count, match in
            guard let range = Range(match.range, in: html) else { return }
            let tag = String(html[range])
            if srcRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil {
                count += 1
            }
        }
    }
}
