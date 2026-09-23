import Foundation
import XCTest

@testable import EmailCore

/// `cid:` 引用改写。
///
/// 邮件里的内嵌图片（签名 logo、商品图）在 HTML 里写的是
/// `<img src="cid:logo@example">` —— WebKit 不知道 `cid:` 是什么协议，
/// **这些图会完全显示不出来**。所以渲染前要把它换成一个我们自己能接住的 scheme。
final class CIDReferenceRewriterTests: XCTestCase {

    // MARK: - 改写

    func testRewritesDoubleQuotedSrc() {
        let html = #"<img src="cid:logo@example" width="80">"#
        XCTAssertEqual(
            CIDReferenceRewriter.rewrite(html),
            #"<img src="mailingo-cid://logo%40example" width="80">"#
        )
    }

    func testRewritesSingleQuotedSrc() {
        let html = "<img src='cid:pic-1@host'>"
        XCTAssertEqual(CIDReferenceRewriter.rewrite(html), #"<img src="mailingo-cid://pic-1%40host">"#)
    }

    func testRewritesUnquotedSrc() {
        let html = "<img src=cid:abc123>"
        XCTAssertEqual(CIDReferenceRewriter.rewrite(html), #"<img src="mailingo-cid://abc123">"#)
    }

    func testRewritesBackgroundAttribute() {
        let html = #"<td background="cid:bg@x">"#
        XCTAssertEqual(
            CIDReferenceRewriter.rewrite(html),
            #"<td background="mailingo-cid://bg%40x">"#
        )
    }

    func testRewritesMultipleReferences() {
        let html = #"<img src="cid:a@x"><img src="cid:b@x">"#
        XCTAssertEqual(
            CIDReferenceRewriter.rewrite(html),
            #"<img src="mailingo-cid://a%40x"><img src="mailingo-cid://b%40x">"#
        )
    }

    /// 大小写不敏感（`CID:` / `SRC=` 都出现过）。
    func testIsCaseInsensitive() {
        let html = #"<IMG SRC="CID:Logo@Example">"#
        XCTAssertEqual(
            CIDReferenceRewriter.rewrite(html),
            #"<IMG SRC="mailingo-cid://Logo%40Example">"#
        )
    }

    // MARK: - 不能碰的东西

    func testLeavesNonCIDAttributesAlone() {
        let html = #"<img src="https://cdn.example.com/logo.png" alt="Logo" style="border:0">"#
        XCTAssertEqual(CIDReferenceRewriter.rewrite(html), html)
    }

    /// 只改 `src` / `background` 的值，其余字节一个都不能动 ——
    /// 和切片管线一个原则。
    func testDoesNotTouchAnythingElse() {
        let html = """
        <a href="https://x.test/cid:not-an-image" class="btn" data-cid="cid:keepme">\
        <img src="cid:real@x"></a>
        """
        let rewritten = CIDReferenceRewriter.rewrite(html)

        XCTAssertTrue(rewritten.contains(#"href="https://x.test/cid:not-an-image""#), "href 不该被改")
        XCTAssertTrue(rewritten.contains(#"data-cid="cid:keepme""#), "data-* 不该被改")
        XCTAssertTrue(rewritten.contains(#"src="mailingo-cid://real%40x""#), "src 应该被改")

        // 把被改写的 src 换回原样后，整段 HTML 必须与原文逐字节相同 ——
        // 也就是"只动了这一个值，其余一个字节都没碰"
        let restored = rewritten.replacingOccurrences(
            of: #"src="mailingo-cid://real%40x""#,
            with: #"src="cid:real@x""#
        )
        XCTAssertEqual(restored, html)
    }

    func testHTMLWithoutCIDIsReturnedUnchanged() {
        let html = "<p>No images here</p>"
        XCTAssertEqual(CIDReferenceRewriter.rewrite(html), html)
    }

    // MARK: - URL 往返

    func testContentIDRoundTrip() {
        for cid in ["logo@example", "a/b+c", "中文图片", "has?question", "has#hash"] {
            let urlString = CIDReferenceRewriter.urlString(forContentID: cid)
            let url = try? XCTUnwrap(URL(string: urlString))
            XCTAssertEqual(
                url.flatMap(CIDReferenceRewriter.contentID(from:)),
                cid,
                "往返失败：\(cid) → \(urlString)"
            )
        }
    }

    func testContentIDFromForeignURLIsNil() {
        XCTAssertNil(CIDReferenceRewriter.contentID(from: URL(string: "https://example.com")!))
        XCTAssertNil(CIDReferenceRewriter.contentID(from: URL(string: "mailingo-cid://")!))
    }

    // MARK: - 端到端：真实 fixture

    /// 拿真实带内嵌图的 fixture 走完整条链路：
    /// MIME 解码 → 取出内嵌资源 → 改写 HTML → 引用能对上资源。
    func testRealFixtureInlineImageBecomesResolvable() throws {
        let analysis = try EmailInspector.analyze(rawMessage: Fixtures.data(Fixtures.relatedGB18030CID))

        // MIME 层：Content-ID 认得出来，字节是合法 PNG
        let resource = try XCTUnwrap(analysis.decoded.inlineResources["logo@example"])
        XCTAssertEqual(resource.mimeType, "image/png")
        XCTAssertEqual([UInt8](resource.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        // 渲染层：HTML 里的 cid: 被改写成自定义 scheme
        let rendered = CIDReferenceRewriter.rewrite(analysis.originalHTML)
        XCTAssertTrue(rendered.contains("mailingo-cid://logo%40example"), rendered)
        XCTAssertFalse(rendered.contains(#"src="cid:"#))

        // 关键闭环：改写出来的 URL 能反解回一个真实存在的资源
        let url = try XCTUnwrap(URL(string: CIDReferenceRewriter.urlString(forContentID: "logo@example")))
        let resolvedID = try XCTUnwrap(CIDReferenceRewriter.contentID(from: url))
        XCTAssertNotNil(analysis.decoded.inlineResources[resolvedID], "改写后的引用找不到对应资源")
    }
}
