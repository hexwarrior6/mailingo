import XCTest
import EmailCore

final class EmailResponsiveLayoutTests: XCTestCase {

    func testInjectIntoHTMLWithHead() {
        let input = "<html><head><title>Test</title></head><body><p>Hello</p></body></html>"
        let output = EmailResponsiveLayout.inject(into: input)

        XCTAssertTrue(output.contains("<style id=\"\(EmailResponsiveLayout.styleID)\">"))
        XCTAssertTrue(output.hasPrefix("<html><head><title>Test</title><style id=\"\(EmailResponsiveLayout.styleID)\">"))
        XCTAssertTrue(output.contains("</style></head><body>"))
    }

    func testInjectIntoHTMLWithUppercaseHead() {
        let input = "<HTML><HEAD><TITLE>Test</TITLE></HEAD><BODY><p>Hello</p></BODY></HTML>"
        let output = EmailResponsiveLayout.inject(into: input)

        XCTAssertTrue(output.contains("<style id=\"\(EmailResponsiveLayout.styleID)\">"))
        XCTAssertTrue(output.contains("</style></HEAD>"))
    }

    func testInjectIntoHTMLWithUnclosedHead() {
        let input = "<html><head><body><p>Hello</p></body></html>"
        let output = EmailResponsiveLayout.inject(into: input)

        XCTAssertTrue(output.contains("<style id=\"\(EmailResponsiveLayout.styleID)\">"))
        XCTAssertTrue(output.hasPrefix("<html><head><style id=\"\(EmailResponsiveLayout.styleID)\">"))
    }

    func testInjectIntoHTMLWithBodyOnly() {
        let input = "<body class=\"email-body\"><p>Hello</p></body>"
        let output = EmailResponsiveLayout.inject(into: input)

        XCTAssertTrue(output.contains("<style id=\"\(EmailResponsiveLayout.styleID)\">"))
        XCTAssertTrue(output.hasPrefix("<body class=\"email-body\"><style id=\"\(EmailResponsiveLayout.styleID)\">"))
    }

    func testInjectIntoHTMLFragment() {
        let input = "<div><p>Fragment only</p></div>"
        let output = EmailResponsiveLayout.inject(into: input)

        XCTAssertTrue(output.hasPrefix("<style id=\"\(EmailResponsiveLayout.styleID)\">"))
        XCTAssertTrue(output.hasSuffix("<div><p>Fragment only</p></div>"))
    }

    func testInjectIsIdempotent() {
        let input = "<html><head></head><body><p>Hello</p></body></html>"
        let first = EmailResponsiveLayout.inject(into: input)
        let second = EmailResponsiveLayout.inject(into: first)

        XCTAssertEqual(first, second, "二次注入不应产生重复的样式块")
    }

    func testNewsletterColumnRatiosSurviveNestedTablesAndBadges() {
        let item = """
        <table style="width:610px"><tbody><tr>
        <td style="width:203.323px"><table width="203"><tr><td width="203">
        <a href="https://example.test/poster"><img src="https://example.test/poster.png" width="203"></a>
        </td></tr></table></td>
        <td style="width:406.677px"><table width="406"><tr><td>Event description</td></tr></table></td>
        </tr></tbody></table>
        """
        let decorated = ImageTranslationOverlay.inject(into: item + item, badges: ["https://example.test/poster.png": .translate])
        let output = EmailResponsiveLayout.inject(into: decorated)
        XCTAssertEqual(output.components(separatedBy: "width:33.331639%;").count - 1, 2)
        XCTAssertEqual(output.components(separatedBy: "width:66.668361%;").count - 1, 2)
        XCTAssertEqual(output.components(separatedBy: "table-layout:fixed;").count - 1, 2)
        XCTAssertTrue(output.contains("<td width=\"203\">"), "Nested single-column cells retain their authored width")
        XCTAssertTrue(output.contains("mailingo-imgtrans://"))
        XCTAssertEqual(output, EmailResponsiveLayout.inject(into: output))
    }

    func testAttributeWidthsAndPointWidthsPreserveRatios() {
        let input = "<TABLE WIDTH='600'><TR><TD WIDTH='200'>Poster</TD><TD style='width:300pt'>Text</TD></TR></TABLE>"
        let output = EmailResponsiveLayout.inject(into: input)
        XCTAssertTrue(output.contains("width:33.333333%;"))
        XCTAssertTrue(output.contains("width:66.666667%;"))
    }

    func testFixedContainersKeepAuthoredMaximumAndAllowMediaQueries() {
        let input = "<table width='150' align='left' class='devicewidth'><tr><td width='150'>Logo</td></tr></table>"
        let output = EmailResponsiveLayout.inject(into: input)
        XCTAssertTrue(output.contains("width:min(100%,150.0px);"))
        XCTAssertTrue(output.contains("<td width='150'>"))
        XCTAssertFalse(output.contains("width:min(100%,150.0px)!important"))
        XCTAssertFalse(EmailResponsiveLayout.css.contains("width: auto !important"))
        XCTAssertFalse(EmailResponsiveLayout.css.contains("\n    width: 100% !important;"))
    }

    func testThreeColumnFooterAllowsIntrinsicIconWidths() {
        let input = "<table width='600'><tr><td width='400'>Text</td><td width='100'>Find us</td><td width='100'>Icons</td></tr></table>"
        let output = EmailResponsiveLayout.inject(into: input)
        XCTAssertTrue(output.contains("table-layout:auto;"))
        XCTAssertTrue(output.contains("width:16.666667%;"))
    }

    func testLaterResponsiveWidthTakesPrecedenceOverEarlierPixels() {
        let input = "<table width='600' style='width:600px;width:100%'><tr><td>Content</td></tr></table>"
        XCTAssertTrue(EmailResponsiveLayout.inject(into: input).hasSuffix(input))
    }

    func testAmbiguousAndDataTablesRemainUntouched() {
        let inputs = [
            "<table width='600'><tr><td width='200'>Image</td><td>Auto</td></tr></table>",
            "<table width='600'><tr><td width='20'>Icon</td><td width='100'>Signature</td></tr></table>",
            "<table width='600'><tr><td width='200'>A</td><td width='400'>B</td></tr><tr><td>C</td><td>D</td></tr></table>",
            "<table width='600'><tr><td width='200' colspan='2'>A</td><td width='400'>B</td></tr></table>",
            "<table width='600'><tr><td width='200' style='border-right:1px solid gray'>Logo</td><td width='400'>Signature</td></tr></table>",
            "<table width='600' style='width:100%'><tr><td width='200'>A</td><td width='400'>B</td></tr></table>"
        ]
        for input in inputs {
            XCTAssertFalse(EmailResponsiveLayout.inject(into: input).contains("table-layout:fixed;"))
        }
    }

    func testMarkupInCommentsAndRawTextDoesNotBecomeAColumnGrid() {
        let fakeTable = "<table width='600'><tr><td width='200'>A</td><td width='400'>B</td></tr></table>"
        for input in ["<!-- \(fakeTable) -->", "<script>const html = \"\(fakeTable)\";</script>", "<textarea>\(fakeTable)</textarea>"] {
            XCTAssertTrue(EmailResponsiveLayout.inject(into: input).hasSuffix(input))
        }
    }

    func testCSSContainsExpectedResponsiveRules() {
        let css = EmailResponsiveLayout.css

        XCTAssertTrue(css.contains("html {"), "应限制 html 的溢出")
        XCTAssertTrue(css.contains("body {"), "应限制 body 的溢出")
        XCTAssertTrue(css.contains("overflow-x: clip !important;"), "应阻断水平滚动且不产生嵌套滚动容器")
        XCTAssertTrue(css.contains("overflow-y: visible !important;"), "应显式声明 body 的垂直溢出为 visible 防止双滚动条")
        XCTAssertTrue(css.contains("table[align=\"left\"]"), "应取消表格浮动防止后续保密声明并排环绕")
        XCTAssertTrue(css.contains("hr {"), "应重置 hr 的浮动清除")
        XCTAssertTrue(css.contains("td[style*=\"border-right\"]:has(img)"), "应保护带右边框的落款多栏图片列不被折叠")
        XCTAssertTrue(css.contains("white-space: nowrap !important;"), "应保持社媒小图标横向平铺不折行")
        XCTAssertTrue(css.contains("img, video, canvas"), "应包含媒体元素自适应")
        XCTAssertTrue(css.contains("max-width: 100% !important;"), "应包含 max-width 约束")
        XCTAssertTrue(css.contains("height: auto !important;"), "应包含图片等比缩放")
        XCTAssertTrue(css.contains("pre"), "应包含代码块防撑破规则")
    }
}
