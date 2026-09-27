import XCTest
import EmailCore

/// 图片翻译角标注入的契约。
///
/// 两条血泪教训钉在这里：
/// 1. 角标 `<a>` **绝不能嵌进外层 `<a>`**（营销邮件的图都包在商品链接里）——
///    HTML 解析器会强制拆锚点、重构 DOM，角标乱飘 + 后续兄弟图片消失；
/// 2. 已翻译的图源必须换 scheme —— WKWebView 缓存自定义 scheme 响应，
///    同 URL 重载拿到的还是原图字节。
final class ImageTranslationOverlayTests: XCTestCase {

    private let cid = "image001.jpg@01DC1234ABCD"
    private let encodedCid = "image001.jpg%4001DC1234ABCD"

    private func img(_ extra: String = "") -> String {
        #"<img src="mailingo-cid://\#(encodedCid)"\#(extra)>"#
    }

    // MARK: - 基本注入

    func testBareImageGetsTranslateBadge() {
        let html = #"<p>hello \#(img()) world</p>"#
        let out = ImageTranslationOverlay.inject(into: html, badges: [cid: .translate])

        XCTAssertTrue(out.contains(#"href="mailingo-imgtrans://\#(encodedCid)""#), "角标 href 应指向翻译动作")
        XCTAssertTrue(out.contains(">文A</a>"))
        XCTAssertTrue(out.contains(#"<span style="position:relative!"#), "装饰层应有定位样式")
        XCTAssertTrue(out.contains(img()), "原图标签原样保留")
    }

    func testRestoreBadgeRewritesSourceToOutputScheme() {
        let html = #"<p>\#(img())</p>"#
        let out = ImageTranslationOverlay.inject(into: html, badges: [cid: .restore])

        XCTAssertTrue(out.contains("mailingo-imgout://\(encodedCid)"), "已翻译的图源必须换成译文 scheme（绕开 WebKit 缓存）")
        XCTAssertFalse(out.contains("mailingo-cid://\(encodedCid)"), "不应再引用原图 scheme")
        XCTAssertTrue(out.contains(">↺</a>"))
    }

    func testBusyBadgeShowsSpinnerAndKeepsOriginalSource() {
        let html = #"<p>\#(img())</p>"#
        let out = ImageTranslationOverlay.inject(into: html, badges: [cid: .busy])

        // 翻译中：SMIL 旋转 loader（SVG 动画，无需页面 JS）
        XCTAssertTrue(out.contains("<animateTransform"), "翻译中应为旋转 loader")
        XCTAssertTrue(out.contains("mailingo-cid://\(encodedCid)"), "翻译中不应改动图源")
    }

    func testUnlistedImageIsUntouched() {
        let html = #"<p>\#(img())</p>"#
        let out = ImageTranslationOverlay.inject(into: html, badges: ["other@cid": .translate])
        XCTAssertEqual(out, html, "不在名单里的图一个字节都不动")
    }

    // MARK: - 锚点包图（营销邮件最常见的形态）

    func testAnchorWrappedImageGetsSiblingBadgeNotNestedAnchor() async throws {
        let html = #"<p><a href="https://shop.example/promo">\#(img())</a></p>"#
        let out = ImageTranslationOverlay.inject(into: html, badges: [cid: .translate])

        // 角标必须是外层锚点的**兄弟**：商品链接完整保留在角标之前
        XCTAssertTrue(out.contains(#"<a href="https://shop.example/promo">"#), "商品链接必须原样保留")
        XCTAssertTrue(out.contains("</a><a href=\"mailingo-imgtrans"), "角标应紧跟在商品锚点闭合之后（兄弟而非嵌套）")
        // img 之前只允许出现一次锚点开标签 —— 不存在嵌套锚点
        let imgIndex = try XCTUnwrap(out.range(of: "<img")).lowerBound
        let anchorOpens = out[..<imgIndex].components(separatedBy: "<a ").count - 1
        XCTAssertEqual(anchorOpens, 1, "img 之前只应有商品链接一个锚点开标签")
    }

    func testAnchorWrappedImageRestoreRewritesSource() {
        let html = #"<p><a href="https://shop.example/promo">\#(img())</a></p>"#
        let out = ImageTranslationOverlay.inject(into: html, badges: [cid: .restore])

        XCTAssertTrue(out.contains("mailingo-imgout://\(encodedCid)"))
        XCTAssertTrue(out.contains(#"<a href="https://shop.example/promo">"#))
    }

    /// 复杂锚点内容（img 外面还包着别的标签）暂不支持 —— 应回退为不注入，
    /// 绝不能产生嵌套锚点。
    func testComplexAnchorContentFallsBackToNoBadge() {
        let html = #"<p><a href="https://shop.example"><span style="x">\#(img())</span></a></p>"#
        let out = ImageTranslationOverlay.inject(into: html, badges: [cid: .translate])

        XCTAssertEqual(out, html, "复杂锚点内容不注入（避免嵌套锚点破坏 DOM）")
    }

    // MARK: - 外部图片（远程）

    func testRemoteImageInsideAnchorGetsSiblingBadge() {
        let html = #"<p><a href="https://shop.example/promo"><img src="https://cdn.example/pic.png"></a></p>"#
        let out = ImageTranslationOverlay.inject(into: html, badges: ["https://cdn.example/pic.png": .translate])

        XCTAssertTrue(out.contains(#"<a href="https://shop.example/promo">"#), "跳转链接必须原样保留")
        XCTAssertTrue(out.contains("</a><a href=\"mailingo-imgtrans"), "角标应为锚点的兄弟（非嵌套）")
        XCTAssertTrue(out.contains(">文A</a>"))
    }

    func testRemoteImageRestoreRewritesWholeSourceValue() {
        // src 里的 &amp; 是 HTML 实体 —— 键必须解码，替换时整段 src 换成 imgout URL
        let html = #"<p><img src="https://cdn.example/pic.png?w=600&amp;h=400"></p>"#
        let key = "https://cdn.example/pic.png?w=600&h=400"
        let out = ImageTranslationOverlay.inject(into: html, badges: [key: .restore])

        XCTAssertTrue(out.contains("mailingo-imgout://https%3A%2F%2Fcdn.example%2Fpic.png%3Fw%3D600%26h%3D400"), "src 应整体换成 imgout URL")
        XCTAssertFalse(out.contains("https://cdn.example/pic.png?w=600"), "不应再引用远程原图")
        XCTAssertTrue(out.contains(">↺</a>"))
    }

    // MARK: - 多图

    func testMultipleImagesEachGetTheirOwnBadge() {
        let cidB = "banner@02DC"
        let html = #"<p>\#(img())</p><p><img src="mailingo-cid://banner%4002DC"></p>"#
        let out = ImageTranslationOverlay.inject(into: html, badges: [cid: .restore, cidB: .translate])

        XCTAssertEqual(out.components(separatedBy: "mailingo-imgtrans://").count - 1, 2)
        XCTAssertTrue(out.contains("mailingo-imgout://\(encodedCid)"), "restore 的图走译文 scheme")
        XCTAssertFalse(out.contains("mailingo-imgout://banner%4002DC"), "translate 的图保持原图源")
    }

    // MARK: - 动作 URL 解析

    func testActionIDRoundTripWithSpecialCharacters() {
        let url = URL(string: ImageTranslationOverlay.actionURLString(forContentID: cid))!
        XCTAssertEqual(ImageTranslationOverlay.actionID(from: url), cid)
    }
}
