import XCTest

@testable import EmailCore

/// MIME 解码。重点覆盖真实邮件里见过、以及历史上踩过的坑：
/// 行尾（LF / CRLF）、传输编码、非 UTF-8 charset、CID、超长头部区。
final class MIMEDecoderTests: XCTestCase {

    private let decoder = RFC822MIMEDecoder()

    // MARK: - 真实邮件

    func testRealSinglePartHTML() throws {
        let decoded = try decoder.decode(Fixtures.data(Fixtures.realSinglepartHTML))

        let html = try XCTUnwrap(decoded.html)
        XCTAssertFalse(html.isEmpty)
        XCTAssertTrue(decoded.plainText == nil)
        XCTAssertEqual(decoded.structureSummary.count, 1)
        XCTAssertTrue(decoded.structureSummary[0].contains("text/html"))
    }

    // MARK: - multipart/alternative + quoted-printable

    func testAlternativePrefersHTMLAndDecodesQuotedPrintable() throws {
        let decoded = try decoder.decode(Fixtures.data(Fixtures.alternativeQP))

        let html = try XCTUnwrap(decoded.html)
        // QP 的软换行必须被正确接上，否则会出现 `= \n` 之类的残留
        XCTAssertFalse(html.contains("=\r\n"), "quoted-printable 软换行没处理干净")
        XCTAssertTrue(html.contains("Your weekly digest is here"))
        XCTAssertTrue(html.contains("Upgrade now"))

        // text/plain 也要拿到，将来可作回退
        let plain = try XCTUnwrap(decoded.plainText)
        XCTAssertTrue(plain.contains("weekly digest"))

        // 两层的结构摘要都要记录
        XCTAssertEqual(decoded.structureSummary.count, 3)
        XCTAssertTrue(decoded.structureSummary[0].contains("multipart/alternative"))
    }

    // MARK: - multipart/related + GB18030 + base64 + CID

    func testRelatedGB18030WithCIDImage() throws {
        let decoded = try decoder.decode(Fixtures.data(Fixtures.relatedGB18030CID))

        let html = try XCTUnwrap(decoded.html)
        // GB18030 解码正确的话，中文应该能读出来
        XCTAssertTrue(html.contains("订单确认"), "GB18030 解码失败")
        XCTAssertTrue(html.contains("已发货"))
        // 属性不能被解码过程破坏
        XCTAssertTrue(html.contains(#"src="cid:logo@example""#))

        // CID 内联图要被收集起来，渲染阶段才能替换成真图
        let resource = try XCTUnwrap(decoded.inlineResources["logo@example"])
        XCTAssertEqual(resource.mimeType, "image/png")
        XCTAssertGreaterThan(resource.data.count, 0)
        // PNG magic number
        XCTAssertEqual([UInt8](resource.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    // MARK: - 超长头部区

    /// 真实 Exchange 邮件的头部区可以超过 8KB。任何"只看前 8KB"的实现都会踩空，
    /// 这个测试把该约束钉住。
    func testHeaderHeavyMessageStillDecodes() throws {
        let raw = try Fixtures.data(Fixtures.headerHeavy)

        // 先确认这个 fixture 真的够"重"
        let bytes = [UInt8](raw)
        var blankOffset = 0
        for i in 0..<(bytes.count - 3) where bytes[i] == 0x0D && bytes[i+1] == 0x0A && bytes[i+2] == 0x0D && bytes[i+3] == 0x0A {
            blankOffset = i
            break
        }
        XCTAssertGreaterThan(blankOffset, 8192, "fixture 的头部区没有超过 8KB，测不到想测的东西")

        let decoded = try decoder.decode(raw)
        let html = try XCTUnwrap(decoded.html)
        XCTAssertTrue(html.contains("Body after a very long header block."))
    }

    // MARK: - 纯文本回退

    func testPlainTextOnlyFallsBackToSynthesisedHTML() throws {
        let analysis = try EmailInspector.analyze(rawMessage: Fixtures.data(Fixtures.plainOnly))

        XCTAssertNil(analysis.decoded.html)
        XCTAssertNotNil(analysis.decoded.plainText)
        XCTAssertTrue(analysis.usedPlainTextFallback)
        XCTAssertTrue(analysis.originalHTML.contains("<p>"))
        XCTAssertTrue(analysis.originalHTML.contains("no HTML part at all"))
        // 空行分段：Hello, 与 Regards, 应该是不同段落
        XCTAssertTrue(analysis.segments.count >= 2)
    }

    // MARK: - 行尾

    /// RFC 5322 规定 CRLF，但 Mail 实测递来的是 LF。
    /// 两种都要能解析，而且**解码结果要一致**。
    func testLFAndCRLFProduceEquivalentResults() throws {
        let crlf = try Fixtures.data(Fixtures.alternativeQP)
        let lf = Data(String(decoding: crlf, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").utf8)

        let fromCRLF = try decoder.decode(crlf)
        let fromLF = try decoder.decode(lf)

        XCTAssertEqual(fromCRLF.html, fromLF.html)
        XCTAssertEqual(fromCRLF.plainText, fromLF.plainText)
        XCTAssertEqual(fromCRLF.inlineResources.count, fromLF.inlineResources.count)

        // 结构摘要里的**字节数**天然会因行尾不同而不同（CRLF 每行多一个字节），
        // 所以这里只比对结构本身：层级、类型、charset。
        XCTAssertEqual(structureWithoutSizes(fromCRLF), structureWithoutSizes(fromLF))
        XCTAssertEqual(fromCRLF.structureSummary.count, 3)
    }

    /// 去掉摘要里的字节数，只留结构信息。
    private func structureWithoutSizes(_ decoded: DecodedEmail) -> [String] {
        decoded.structureSummary.map {
            $0.replacingOccurrences(of: #"\s*\d+ B"#, with: "", options: .regularExpression)
        }
    }

    // MARK: - 传输编码

    func testBase64AndQuotedPrintableAndIdentity() throws {
        let body = "<p>café &amp; 汉字</p>"
        let b64 = Data(body.utf8).base64EncodedString()
        let qp = body.utf8.map { byte -> String in
            if byte >= 0x20 && byte < 0x7F && byte != 0x3D { return String(UnicodeScalar(byte)) }
            return String(format: "=%02X", byte)
        }.joined()

        for (encoding, payload) in [
            ("base64", b64),
            ("quoted-printable", qp),
            ("8bit", body)
        ] {
            let raw = Data("""
            From: a@b.c\r
            Content-Type: text/html; charset="utf-8"\r
            Content-Transfer-Encoding: \(encoding)\r
            \r
            \(payload)
            """.utf8)
            let decoded = try decoder.decode(raw)
            XCTAssertEqual(decoded.html, body, "传输编码 \(encoding) 解码不对")
        }
    }

    // MARK: - 健壮性

    func testEmptyMessageThrows() {
        XCTAssertThrowsError(try decoder.decode(Data()))
    }

    func testMessageWithNoHeaderBodySeparatorIsTolerated() throws {
        let raw = Data("Subject: only headers".utf8)
        let decoded = try decoder.decode(raw)
        XCTAssertNil(decoded.html)
        XCTAssertNil(decoded.plainText)
    }
}
