import Foundation
import XCTest

@testable import EmailCore

/// 头部解析与 RFC 2047 解码。
///
/// 这份逻辑踩过两个真实的坑（CRLF 切分、头部名大小写），而且原先散在两个地方。
/// 合并成一处之后用这些测试钉住 —— 两个坑各自都有专门的用例。
final class MIMEHeadersTests: XCTestCase {

    // MARK: - charset 超集回退（真实缺陷，2026-09-24）

    /// **声明 gb2312、正文里却有 GBK 独有的字节**时必须仍能解出来。
    ///
    /// 实测的真实邮件：2260 字节的正文里只有一个 `A8 43`（GBK 的短破折号
    /// 「–」，GB2312 里没有这个码位）。而 `String(data:encoding:)` 是
    /// **全有或全无**的 —— 这一个字节让整段返回 nil，接着掉进 Latin-1 兜底，
    /// 整篇中文变成「Èñ½ÝÍøÂç」。实测击中了 6 封真实邮件。
    func testGB2312BodyContainingGBKOnlyByteStillDecodes() {
        // 「锐捷网络」+ GBK 独有的「–」(A8 43)
        let bytes = Data([0xC8, 0xF1, 0xBD, 0xDD, 0xCD, 0xF8, 0xC2, 0xE7, 0xA8, 0x43])
        XCTAssertEqual(MIMEHeaders.decodeText(bytes, charset: "gb2312"), "锐捷网络–")
    }

    /// 超集回退只在**严格解失败**时才发生 —— 能解的邮件行为必须一字不变。
    func testStrictCharsetDecodeStillWins() {
        let bytes = Data([0xC8, 0xF1, 0xBD, 0xDD, 0xCD, 0xF8, 0xC2, 0xE7])
        XCTAssertEqual(MIMEHeaders.decodeText(bytes, charset: "gb2312"), "锐捷网络")
        // 名字大小写与首尾空白都要被规范化
        XCTAssertEqual(MIMEHeaders.decodeText(bytes, charset: "GBK"), "锐捷网络")
        XCTAssertEqual(MIMEHeaders.decodeText(bytes, charset: "  GB2312  "), "锐捷网络")
    }

    /// 认不出的 charset 仍然走原来的兜底，不会被超集表牵连。
    func testUnknownCharsetKeepsItsFallback() {
        XCTAssertEqual(MIMEHeaders.decodeText(Data("hello".utf8), charset: "x-nope"), "hello")
        // 非 UTF-8 的高位字节最终按 Latin-1 解 —— 这是刻意保留的最后一档
        XCTAssertEqual(MIMEHeaders.decodeText(Data([0xE9]), charset: "x-nope"), "é")
        XCTAssertEqual(MIMEHeaders.decodeText(Data([0xE9]), charset: ""), "é")
    }

    /// 繁体中文同族也要退到超集。
    ///
    /// `A1 AA` 在 Apple 的 big5 实现里解不出来、在 big5-hkscs 里可以 ——
    /// 如果回退没生效，它就会掉进 Latin-1 变成「¡ª」。
    func testBig5FallsBackToHKSCS() {
        let text = MIMEHeaders.decodeText(Data([0xA1, 0xAA]), charset: "big5")
        XCTAssertNotNil(text)
        XCTAssertNotEqual(text, "¡ª", "掉进 Latin-1 兜底，说明没有回退到 big5-hkscs")
    }

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
