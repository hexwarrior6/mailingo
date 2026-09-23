import Foundation
import XCTest

@testable import EmailCore

/// 外部图片计数。用来在界面上明说「已拦截 N 张外部图片」，
/// 而不是让用户面对几个空白格子猜原因。
final class RemoteContentScannerTests: XCTestCase {

    func testCountsRemoteImages() {
        let html = """
        <img src="https://cdn.example.com/a.png">
        <img src="http://cdn.example.com/b.png">
        <img src="https://cdn.example.com/c.png" alt="x">
        """
        XCTAssertEqual(RemoteContentScanner.remoteImageCount(in: html), 3)
    }

    func testIgnoresLocalAndInlineImages() {
        let html = """
        <img src="cid:logo@example">
        <img src="data:image/png;base64,iVBORw0KGgo=">
        <img src="/relative/path.png">
        <img alt="no src at all">
        """
        XCTAssertEqual(RemoteContentScanner.remoteImageCount(in: html), 0)
    }

    func testIsCaseInsensitiveAndHandlesQuoteStyles() {
        let html = """
        <IMG SRC="HTTPS://CDN.EXAMPLE.COM/A.PNG">
        <img src='https://cdn.example.com/b.png'>
        <img src=https://cdn.example.com/c.png>
        """
        XCTAssertEqual(RemoteContentScanner.remoteImageCount(in: html), 3)
    }

    /// 真实案例：营销邮件把 emoji 做成远程图片。
    func testRealWorldEmojiAsRemoteImages() {
        let html = """
        <p><img alt="🌍" width="18" height="18" src="https://web.telegram.org/k/assets/img/emoji/1f30d.png">Midea</p>
        <p><img alt="✨" width="18" height="18" src="https://web.telegram.org/k/assets/img/emoji/2728.png">What You Can Get</p>
        <p>📅 日期　📍 地点</p>
        """
        XCTAssertEqual(RemoteContentScanner.remoteImageCount(in: html), 2)
    }

    func testDoesNotCountRemoteLinksOrScripts() {
        let html = """
        <a href="https://example.com/page">link</a>
        <img src="cid:x">
        """
        XCTAssertEqual(RemoteContentScanner.remoteImageCount(in: html), 0)
    }

    /// 真实 fixture 里那张追踪像素与 logo 都是远程图。
    func testRealFixtureRemoteImageCount() throws {
        let analysis = try EmailInspector.analyze(rawMessage: Fixtures.data(Fixtures.alternativeQP))
        // 营销邮件 fixture 里有 logo + 追踪像素两张远程图
        XCTAssertEqual(RemoteContentScanner.remoteImageCount(in: analysis.originalHTML), 2)
    }
}
