import Foundation
import XCTest

@testable import EmailCore

/// 头部解析与 RFC 2047 解码。
///
/// 这份逻辑踩过两个真实的坑（CRLF 切分、头部名大小写），而且原先散在两个地方。
/// 合并成一处之后用这些测试钉住 —— 两个坑各自都有专门的用例。
final class MIMEHeadersTests: XCTestCase {

    // MARK: - 行尾：这是踩过的坑之一

    /// CRLF 必须能正确切分。
    ///
    /// 早先用 `components(separatedBy: .newlines)`：CRLF 会被拆成两个分隔符，
    /// 中间多出空串，于是"读到空行就结束"的逻辑在第一行后就退出，
    /// 后面的头部全部读不到。而 `split(separator: "\n")` 更糟 ——
    /// **在 Swift 里 `"\r\n"` 是单个 Character**，它根本不在 CRLF 处切分。
    func testParsesCRLFLineEndings() {
        let raw = "From: a@b.c\r\nSubject: hello\r\nContent-Type: text/html\r\n\r\nbody"
        let headers = MIMEHeaders.parse(text: raw)

        XCTAssertEqual(headers["from"], "a@b.c")
        XCTAssertEqual(headers["subject"], "hello")
        XCTAssertEqual(headers["content-type"], "text/html")
    }

    func testParsesLFLineEndings() {
        let raw = "From: a@b.c\nSubject: hello\n\nbody"
        let headers = MIMEHeaders.parse(text: raw)

        XCTAssertEqual(headers["from"], "a@b.c")
        XCTAssertEqual(headers["subject"], "hello")
    }

    func testLFAndCRLFProduceTheSameResult() {
        let crlf = "From: a@b.c\r\nSubject: hello\r\nX-Long: 1\r\n\r\nbody"
        let lf = crlf.replacingOccurrences(of: "\r\n", with: "\n")

        XCTAssertEqual(MIMEHeaders.parse(text: crlf), MIMEHeaders.parse(text: lf))
    }

    // MARK: - 头部名大小写：这是踩过的另一个坑

    /// 头部名大小写不敏感。真实邮件里 `SUBJECT:`、`From:`、`content-type:` 都出现过。
    func testHeaderNamesAreCaseInsensitive() {
        let raw = "SUBJECT: Upper\r\nFrom: a@b.c\r\nCONTENT-TYPE: text/plain\r\n\r\nbody"
        let headers = MIMEHeaders.parse(text: raw)

        XCTAssertEqual(headers["subject"], "Upper")
        XCTAssertEqual(headers["from"], "a@b.c")
        XCTAssertEqual(headers["content-type"], "text/plain")
        XCTAssertEqual(MIMEHeaders.value("Subject", in: headers), "Upper")
        XCTAssertEqual(MIMEHeaders.value("SUBJECT", in: headers), "Upper")
    }

    // MARK: - 折行

    func testFoldedHeadersAreJoined() {
        let raw = "Subject: first part\r\n second part\r\n\tthird part\r\n\r\nbody"
        XCTAssertEqual(MIMEHeaders.parse(text: raw)["subject"], "first part second part third part")
    }

    /// 头部与正文之间的空行必须终止解析 —— 正文里出现 "X: y" 不能被当成头部。
    func testBodyIsNotParsedAsHeaders() {
        let raw = "Subject: real\r\n\r\nNote: this is body text\r\nAnother: line"
        let headers = MIMEHeaders.parse(text: raw)

        XCTAssertEqual(headers["subject"], "real")
        XCTAssertNil(headers["note"])
        XCTAssertNil(headers["another"])
    }

    // MARK: - RFC 2047

    func testDecodesBase64EncodedWord() {
        // "=?utf-8?B?5L2g5aW9?=" 是「你好」的 UTF-8 base64
        XCTAssertEqual(MIMEHeaders.decodeRFC2047("=?utf-8?B?5L2g5aW9?="), "你好")
    }

    func testDecodesQuotedPrintableEncodedWord() {
        XCTAssertEqual(MIMEHeaders.decodeRFC2047("=?utf-8?Q?caf=C3=A9?="), "café")
    }

    /// Q 编码里下划线代表空格 —— 这个很容易漏。
    func testQuotedPrintableUnderscoreBecomesSpace() {
        XCTAssertEqual(MIMEHeaders.decodeRFC2047("=?utf-8?Q?Your_weekly_digest?="), "Your weekly digest")
    }

    func testDecodesEncodedWordEmbeddedInPlainText() {
        XCTAssertEqual(
            MIMEHeaders.decodeRFC2047("Re: =?utf-8?B?5L2g5aW9?= (fwd)"),
            "Re: 你好 (fwd)"
        )
    }

    func testDecodesMultipleEncodedWords() {
        XCTAssertEqual(
            MIMEHeaders.decodeRFC2047("=?utf-8?B?5L2g?= =?utf-8?B?5aW9?="),
            "你好"
        )
    }

    func testPlainTextIsReturnedUnchanged() {
        XCTAssertEqual(MIMEHeaders.decodeRFC2047("Just a normal subject"), "Just a normal subject")
    }

    func testMalformedEncodedWordIsLeftAlone() {
        // 不完整的编码词不能把整串吃掉
        XCTAssertEqual(MIMEHeaders.decodeRFC2047("=?utf-8?B?broken"), "=?utf-8?B?broken")
    }

    /// 非 UTF-8 的编码词（中文邮件里很常见）。
    func testDecodesGB18030EncodedWord() {
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let raw = "订单确认"
        guard let bytes = raw.data(using: encoding) else {
            return XCTFail("无法用 GB18030 编码测试串")
        }

        let encoded = "=?gb18030?B?\(bytes.base64EncodedString())?="
        XCTAssertEqual(MIMEHeaders.decodeRFC2047(encoded), raw)
    }

    // MARK: - 与真实 fixture 对齐

    /// fixture 里的主题就是 RFC 2047 编码的，顺便验证解析链路。
    func testParsesFixtureSubject() throws {
        let headers = MIMEHeaders.parse(try Fixtures.data(Fixtures.alternativeQP))
        let subject = MIMEHeaders.decodeRFC2047(MIMEHeaders.value("subject", in: headers) ?? "")

        XCTAssertEqual(subject, "Your weekly digest is here")
        XCTAssertEqual(MIMEHeaders.value("content-type", in: headers)?.hasPrefix("multipart/alternative"), true)
    }
}
