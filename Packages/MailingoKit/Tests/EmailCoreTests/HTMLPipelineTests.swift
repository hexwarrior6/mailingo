import XCTest

@testable import EmailCore

/// HTML 保真管线 —— 本方案的核心。这些断言就是 `docs/IMPLEMENTATION_PLAN.md`
/// §6「HTML 保真（最高优先级）」那一条的落地。
final class HTMLPipelineTests: XCTestCase {

    // MARK: - 保真：非文本字节必须一个都不变

    /// 最强的那条断言：切片前后，**非文本字节 100% 一致**。
    func testSplicePreservesEveryNonTextByte() throws {
        for fixture in [Fixtures.realSinglepartHTML, Fixtures.alternativeQP] {
            let analysis = try EmailInspector.analyze(rawMessage: Fixtures.data(fixture))
            let inspection = EmailInspector.apply(
                translations: markerTranslations(for: analysis),
                to: analysis
            )

            XCTAssertEqual(
                HTMLTokenizer.skeleton(of: analysis.originalHTML),
                HTMLTokenizer.skeleton(of: inspection.splicedHTML),
                "[\(fixture)] 非文本字节被改动了"
            )
            XCTAssertEqual(
                HTMLTokenizer.tagSequence(in: analysis.originalHTML),
                HTMLTokenizer.tagSequence(in: inspection.splicedHTML),
                "[\(fixture)] 标签序列被改动了"
            )
            XCTAssertGreaterThan(inspection.segments.count, 0, "[\(fixture)] 一个片段都没提取到")
        }
    }

    /// 跑一遍自检 API，确认它自己也是通过的（避免自检逻辑本身是坏的）。
    func testRuntimeFidelityReportIsClean() throws {
        let analysis = try EmailInspector.analyze(rawMessage: Fixtures.data(Fixtures.realSinglepartHTML))
        let inspection = EmailInspector.apply(translations: markerTranslations(for: analysis), to: analysis)

        XCTAssertTrue(inspection.fidelity.nonTextBytesIdentical, inspection.fidelity.detail)
        XCTAssertTrue(inspection.fidelity.tagSequenceIdentical, inspection.fidelity.detail)
        XCTAssertEqual(inspection.fidelity.changedSegmentCount, analysis.segments.count)
    }

    /// 译文与原文相同时，结果必须**逐字节**等于原文。
    ///
    /// 这条能成立靠的是 `HTMLSplicer` 对"未改动片段写回原始字节"的处理 ——
    /// 否则 `&#233;` 会被规范化成 `é`，字节就变了。
    func testIdentityTranslationIsByteIdentical() throws {
        let analysis = try EmailInspector.analyze(rawMessage: Fixtures.data(Fixtures.realSinglepartHTML))
        let identity = Dictionary(uniqueKeysWithValues: analysis.segments.map { ($0.id, $0.sourceText) })
        let spliced = HTMLSplicer.splice(
            html: analysis.originalHTML,
            segments: analysis.segments,
            translations: identity
        )
        XCTAssertEqual(spliced, analysis.originalHTML)
    }

    /// 没有任何文本节点的 HTML，切片必须原样返回（属性测试的定性版本）。
    func testHTMLWithoutTextNodesIsUnchanged() {
        let html = #"<table><tr><td><img src="a.png"></td><td></td></tr></table>"#
        let segments = SegmentExtractor.extract(from: html)
        XCTAssertTrue(segments.isEmpty)
        XCTAssertEqual(HTMLSplicer.splice(html: html, segments: segments, translations: [:]), html)
    }

    // MARK: - 该跳过的必须跳过

    func testScriptAndStyleContentIsNeverExtracted() {
        let html = """
        <html><head><style>.a{color:red}</style>
        <script>var greeting = "translate me not";</script></head>
        <body><p>Translate me</p></body></html>
        """
        let texts = SegmentExtractor.extract(from: html).map(\.sourceText)
        XCTAssertEqual(texts, ["Translate me"])
    }

    func testCommentAndConditionalCommentAreUntouched() {
        let html = #"<!--[if mso]><table><tr><td><![endif]--><p>Hello</p><!--[if mso]></td></tr></table><![endif]-->"#
        let analysis = EmailAnalysis(
            decoded: DecodedEmail(),
            originalHTML: html,
            usedPlainTextFallback: false,
            segments: SegmentExtractor.extract(from: html)
        )
        let spliced = EmailInspector.apply(translations: markerTranslations(for: analysis), to: analysis).splicedHTML

        XCTAssertTrue(spliced.contains("<!--[if mso]><table><tr><td><![endif]-->"))
        XCTAssertTrue(spliced.contains("<!--[if mso]></td></tr></table><![endif]-->"))
        XCTAssertFalse(spliced.contains("Hello"))
    }

    func testAttributesAreNeverRewritten() {
        let html = #"<a href="https://x.test/?a=1&amp;b=2" class="btn" data-id="7" style="color:red">Click</a>"#
        let segments = SegmentExtractor.extract(from: html)
        let spliced = HTMLSplicer.splice(html: html, segments: segments, translations: [0: "点击"])

        XCTAssertTrue(spliced.contains(#"href="https://x.test/?a=1&amp;b=2""#))
        XCTAssertTrue(spliced.contains(#"data-id="7""#))
        XCTAssertTrue(spliced.contains(#"style="color:red""#))
        XCTAssertTrue(spliced.contains(">点击</a>"))
    }

    func testPlainNumbersAndURLsAreNotTranslated() {
        let html = """
        <p>2026</p><p>--</p><p>https://example.com/a?b=1</p><p>user@example.com</p><p>Real text</p>
        """
        XCTAssertEqual(SegmentExtractor.extract(from: html).map(\.sourceText), ["Real text"])
    }

    // MARK: - 空白与实体

    func testWhitespaceBetweenInlineTagsIsPreserved() {
        let html = "<p><b>Hello</b> <i>world</i></p>"
        let segments = SegmentExtractor.extract(from: html)
        XCTAssertEqual(segments.map(\.sourceText), ["Hello", "world"])

        let spliced = HTMLSplicer.splice(
            html: html,
            segments: segments,
            translations: [0: "你好", 1: "世界"]
        )
        // 两个 <b>/<i> 之间那个空格必须还在
        XCTAssertEqual(spliced, "<p><b>你好</b> <i>世界</i></p>")
    }

    func testEntitiesAreDecodedThenReescaped() {
        let html = "<p>Tom &amp; Jerry &lt;3 caf&eacute; &nbsp;end</p>"
        let segments = SegmentExtractor.extract(from: html)
        XCTAssertEqual(segments.count, 1)
        // 注意 `café` 与 `&nbsp;` 之间那个**普通空格**要保留，
        // 它和 nbsp 是两个不同的空白字符，不能混为一谈。
        XCTAssertEqual(segments[0].sourceText, "Tom & Jerry <3 café \u{00A0}end")

        let spliced = HTMLSplicer.splice(
            html: html,
            segments: segments,
            translations: [0: "汤姆 & 杰瑞 <3 咖啡 \u{00A0}结束"]
        )
        XCTAssertEqual(spliced, "<p>汤姆 &amp; 杰瑞 &lt;3 咖啡 &nbsp;结束</p>")
    }

    func testUnknownEntityIsLeftAlone() {
        XCTAssertEqual(HTMLEntities.decode("a &weirdthing; b"), "a &weirdthing; b")
        XCTAssertEqual(HTMLEntities.decode("&#65;&#x42;"), "AB")
    }

    /// 未闭合的 `<` 不能把后面的正文整段吃掉。
    func testUnclosedAngleBracketDoesNotSwallowTheRest() {
        let html = "<p>a < b</p><p>second</p>"
        let texts = SegmentExtractor.extract(from: html).map(\.sourceText)
        XCTAssertTrue(texts.contains("second"), "第二个段落被吞掉了：\(texts)")
    }

    /// 把 App 右侧预览窗格的内容钉住：标记确实插进去了，
    /// 而**非文本**东西确实还在。
    ///
    /// 注意断言要跟着 fixture 走：真实那封是 ServiceNow 通知，里面**没有图片**，
    /// 所以图片相关的断言放到带图片的合成 fixture 上（见下一个测试）。
    func testMarkerSplicedRealFixtureKeepsStructureAndInsertsMarkers() throws {
        let analysis = try EmailInspector.analyze(rawMessage: Fixtures.data(Fixtures.realSinglepartHTML))
        let inspection = EmailInspector.apply(translations: markerTranslations(for: analysis), to: analysis)

        XCTAssertFalse(inspection.usedPlainTextFallback)
        XCTAssertGreaterThan(inspection.segments.count, 0)

        // 标记出现在结果里
        XCTAssertTrue(inspection.splicedHTML.contains("〖0〗"))
        // 结构性的东西一个都没丢
        XCTAssertTrue(inspection.splicedHTML.contains("href="))
        XCTAssertTrue(inspection.splicedHTML.contains("<table"))
        XCTAssertTrue(inspection.splicedHTML.contains("<style>"))
        // 原文里的 URL 没被当成文本翻译掉
        for segment in analysis.segments {
            XCTAssertFalse(segment.sourceText.hasPrefix("http"), "URL 被送去翻译了：\(segment.sourceText)")
        }
    }

    /// 带图片、条件注释和按钮的营销邮件：切片后这些必须原样都在。
    func testMarkerSplicedMarketingFixtureKeepsImagesAndConditionalComments() throws {
        let analysis = try EmailInspector.analyze(rawMessage: Fixtures.data(Fixtures.alternativeQP))
        let inspection = EmailInspector.apply(translations: markerTranslations(for: analysis), to: analysis)

        XCTAssertTrue(inspection.splicedHTML.contains("<img"))
        XCTAssertTrue(inspection.splicedHTML.contains("<!--[if mso]>"))
        XCTAssertTrue(inspection.splicedHTML.contains("class=\"btn\""))
        XCTAssertTrue(inspection.splicedHTML.contains("utm_source=email&amp;utm_medium=digest"))
        // 追踪像素的 src 也不能被动
        XCTAssertTrue(inspection.splicedHTML.contains("track.example.com/open.gif"))
    }

    // MARK: - 辅助

    private func markerTranslations(for analysis: EmailAnalysis) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: analysis.segments.map { ($0.id, "〖\($0.id)〗") })
    }
}
