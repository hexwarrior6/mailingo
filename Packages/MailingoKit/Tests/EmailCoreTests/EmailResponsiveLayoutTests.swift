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

    func testCSSContainsExpectedResponsiveRules() {
        let css = EmailResponsiveLayout.css

        XCTAssertTrue(css.contains("html {"), "应限制 html 的溢出")
        XCTAssertTrue(css.contains("body {"), "应限制 body 的溢出")
        XCTAssertTrue(css.contains("overflow-x: clip !important;"), "应阻断水平滚动且不产生嵌套滚动容器")
        XCTAssertTrue(css.contains("overflow-y: visible !important;"), "应显式声明 body 的垂直溢出为 visible 防止双滚动条")
        XCTAssertTrue(css.contains("table[width]:not([width$=\"%\"])"), "应重置非百分比表格宽度")
        XCTAssertTrue(css.contains("table[style*=\"width\"]:not([style*=\"%\"])"), "应重置非百分比行内宽度表格")
        XCTAssertTrue(css.contains("img, video, canvas"), "应包含媒体元素自适应")
        XCTAssertTrue(css.contains("max-width: 100% !important;"), "应包含 max-width 约束")
        XCTAssertTrue(css.contains("height: auto !important;"), "应包含图片等比缩放")
        XCTAssertTrue(css.contains("pre"), "应包含代码块防撑破规则")
    }
}
