import XCTest
@testable import EmailCore

final class ReplyQuoteTests: XCTestCase {
    func testAppleQuotesAreExcludedButInlineRepliesRemain() throws {
        let html = "<p>Current answer</p><div>On Monday, Alex wrote:</div><blockquote type='cite'><p>Old question</p><blockquote type='cite'>Older question</blockquote></blockquote><p>Another current answer</p>"
        XCTAssertEqual(try texts(html), ["Current answer", "Another current answer"])
    }

    func testClientQuoteContainersAndTokenMatching() throws {
        for client in ["gmail_quote", "gmail_quote_container", "yahoo_quoted", "protonmail_quote"] {
            XCTAssertEqual(try texts("<p>New reply</p><div CLASS='other \(client)'><p>History</p></div>"), ["New reply"])
        }
        XCTAssertEqual(try texts("<div class='not_gmail_quote'>Current body</div>"), ["Current body"])
    }

    func testOutlookHeaderStartsHistoryAcrossSiblings() throws {
        XCTAssertEqual(try texts("<p>Current reply</p><div id=divRplyFwdMsg><b>From:</b> Alex</div><p>Old reply</p>"), ["Current reply"])
    }

    func testOrdinaryBlockquoteStillTranslates() throws {
        XCTAssertEqual(try texts("<p>Review this quote:</p><blockquote>A literary quote</blockquote><p>My comments</p>"), ["Review this quote:", "A literary quote", "My comments"])
    }

    func testPlainReplyWithoutBlankLineAndInlineResponse() throws {
        let plain = "New reply\n> Old question\nInline response\n>> Older question"
        let analysis = try analyzePlain(plain)
        XCTAssertEqual(analysis.segments.map(\.sourceText), ["New reply", "Inline response"])
        let result = try EmailInspector.apply(translations: [0: "新回复", 1: "补充回答"], to: analysis)
        XCTAssertTrue(result.splicedHTML.contains("&gt; Old question"))
        XCTAssertTrue(result.splicedHTML.contains("&gt;&gt; Older question"))
        XCTAssertTrue(result.fidelity.nonTextBytesIdentical)
    }

    func testPlainAttributionAndOriginalMessageSeparators() throws {
        for separator in ["On Monday, Alex wrote:", "-----Original Message-----", "-----原始邮件-----"] {
            let analysis = try analyzePlain("Current reply\n\(separator)\nOld body\nOlder body")
            XCTAssertEqual(analysis.segments.map(\.sourceText), ["Current reply"])
        }
    }

    func testHistoryIsUntouchedAndIDsAreDense() throws {
        let html = "<p>First reply</p><blockquote type=\"cite\"><table><tr><td>Old &amp; important</td></tr></table></blockquote><p>Second reply</p>"
        let segments = try SegmentExtractor.extract(from: html)
        XCTAssertEqual(segments.map(\.id), [0, 1])
        let result = HTMLSplicer.splice(html: html, segments: segments, translations: [0: "第一回复", 1: "第二回复"])
        XCTAssertTrue(result.contains("<blockquote type=\"cite\"><table><tr><td>Old &amp; important</td></tr></table></blockquote>"))
        XCTAssertTrue(try HTMLSplicer.verifyFidelity(original: html, spliced: result).nonTextBytesIdentical)
    }

    private func texts(_ html: String) throws -> [String] {
        try SegmentExtractor.extract(from: html).map(\.sourceText)
    }

    private func analyzePlain(_ plain: String) throws -> EmailAnalysis {
        try EmailInspector.analyze(rawMessage: Data("Content-Type: text/plain; charset=utf-8\r\n\r\n\(plain)".utf8))
    }
}
