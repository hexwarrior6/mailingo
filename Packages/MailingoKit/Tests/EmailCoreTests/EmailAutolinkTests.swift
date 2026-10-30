import Foundation
import XCTest

@testable import EmailCore

final class EmailAutolinkTests: XCTestCase {

    func testLinkifiesPlainTextHttpAndHttps() {
        let html = "<p>Visit https://go.blueja.io/AloKiP6zNEy-Kho8_PkI_Q for survey.</p>"
        let expected = #"<p>Visit <a href="https://go.blueja.io/AloKiP6zNEy-Kho8_PkI_Q">https://go.blueja.io/AloKiP6zNEy-Kho8_PkI_Q</a> for survey.</p>"#
        XCTAssertEqual(EmailAutolink.linkify(html), expected)
    }

    func testLinkifiesMultipleLinksInSameTextRun() {
        let html = "<p>Dr S Supraja: https://go.blueja.io/AloKiP6zNEy-Kho8_PkI_Q, Dr Simon Liu: https://go.blueja.io/eyRA7_lBB0-VNhjjFLbY-g</p>"
        let expected = #"<p>Dr S Supraja: <a href="https://go.blueja.io/AloKiP6zNEy-Kho8_PkI_Q">https://go.blueja.io/AloKiP6zNEy-Kho8_PkI_Q</a>, Dr Simon Liu: <a href="https://go.blueja.io/eyRA7_lBB0-VNhjjFLbY-g">https://go.blueja.io/eyRA7_lBB0-VNhjjFLbY-g</a></p>"#
        XCTAssertEqual(EmailAutolink.linkify(html), expected)
    }

    func testDoesNotNestInsideExistingAnchors() {
        let html = #"<p><a href="https://example.com">https://example.com</a> and <span><a href="https://other.com"><span>nested https://example.com</span></a></span></p>"#
        XCTAssertEqual(EmailAutolink.linkify(html), html)
    }

    func testDoesNotTouchScriptOrStyle() {
        let html = """
        <style>@import url('https://fonts.googleapis.com');</style>
        <p>Text https://example.com</p>
        """
        let expected = """
        <style>@import url('https://fonts.googleapis.com');</style>
        <p>Text <a href="https://example.com">https://example.com</a></p>
        """
        XCTAssertEqual(EmailAutolink.linkify(html), expected)
    }

    func testHandlesAmpersandInQuery() {
        let html = "<p>https://example.com?a=1&amp;b=2</p>"
        let expected = #"<p><a href="https://example.com?a=1&amp;b=2">https://example.com?a=1&amp;b=2</a></p>"#
        XCTAssertEqual(EmailAutolink.linkify(html), expected)
    }

    func testExcludesTrailingPunctuation() {
        let html = "<p>Visit https://example.com. Also (https://test.org)!</p>"
        let expected = #"<p>Visit <a href="https://example.com">https://example.com</a>. Also (<a href="https://test.org">https://test.org</a>)!</p>"#
        XCTAssertEqual(EmailAutolink.linkify(html), expected)
    }

    func testLinkifiesEmailAddresses() {
        let html = "<p>Contact supraja.s@ntu.edu.sg for assistance.</p>"
        let expected = #"<p>Contact <a href="mailto:supraja.s@ntu.edu.sg">supraja.s@ntu.edu.sg</a> for assistance.</p>"#
        XCTAssertEqual(EmailAutolink.linkify(html), expected)
    }

    func testIsIdempotent() {
        let html = "<p>Check https://example.com and contact test@example.com.</p>"
        let once = EmailAutolink.linkify(html)
        let twice = EmailAutolink.linkify(once)
        XCTAssertEqual(once, twice)
    }

    func testPreservesUnmodifiedHtmlBytes() {
        let html = "<p>Hello world without any links or emails.</p>"
        XCTAssertEqual(EmailAutolink.linkify(html), html)
    }

    func testUserReportedSurveyEmailSnippet() {
        let html = """
        <p>Dr S Supraja: <span style="color: #046ef6"><span style="text-decoration:underline;">https://go.blueja.io/AloKiP6zNEy-Kho8_PkI_Q</span></span></p>
        <p>Dr Simon Liu: <span style="color: #046ef6"><span style="text-decoration:underline;">https://go.blueja.io/eyRA7_lBB0-VNhjjFLbY-g</span></span></p>
        """
        let expected = """
        <p>Dr S Supraja: <span style="color: #046ef6"><span style="text-decoration:underline;"><a href="https://go.blueja.io/AloKiP6zNEy-Kho8_PkI_Q">https://go.blueja.io/AloKiP6zNEy-Kho8_PkI_Q</a></span></span></p>
        <p>Dr Simon Liu: <span style="color: #046ef6"><span style="text-decoration:underline;"><a href="https://go.blueja.io/eyRA7_lBB0-VNhjjFLbY-g">https://go.blueja.io/eyRA7_lBB0-VNhjjFLbY-g</a></span></span></p>
        """
        XCTAssertEqual(EmailAutolink.linkify(html), expected)
    }
}
