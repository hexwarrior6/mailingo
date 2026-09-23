import Foundation
import XCTest

@testable import EmailCore

/// 「被标签切开的孤立虚词」。
///
/// 起因是两个真实案例：
/// - `<b>9:00</b> to <b>11:00</b>` 里的 `to` —— 单独送翻译时没有语境
/// - `14<sup>th</sup>` 里的 `th` —— 它压根不是一个词，只是序数后缀
///
/// Apple 翻译的接口只收"要翻的这段文本"，看不到上下文，这类片段翻出来往往是错的。
/// 现在的策略是**整段保留原文**（翻错比不翻更糟），等有了能拿完整上下文的
/// LLM 引擎再交给它翻。
final class OrphanSegmentTests: XCTestCase {

    // MARK: - 用户报告的两个案例

    func testPrepositionBetweenBoldNumbersIsMarkedOrphan() throws {
        let html = "<p>Meeting from <b>9:00</b> to <b>11:00</b></p>"
        let segments = SegmentExtractor.extract(from: html)

        let orphan = try XCTUnwrap(segments.first { $0.sourceText == "to" })
        XCTAssertTrue(orphan.isContextlessOrphan, "夹在两个加粗时间之间的 to 应被标记为孤立片段")

        // 同一个块里其余有实义的片段不受影响
        let leading = try XCTUnwrap(segments.first { $0.sourceText == "Meeting from" })
        XCTAssertFalse(leading.isContextlessOrphan)

        // 纯数字不会成为片段，但它们的存在是"我在句子中间"的证据
        XCTAssertNil(segments.first { $0.sourceText == "9:00" })
        XCTAssertNil(segments.first { $0.sourceText == "11:00" })
    }

    func testOrdinalSuffixInSuperscriptIsMarkedOrphan() throws {
        let html = "<p>Due on 14<sup>th</sup> March</p>"
        let segments = SegmentExtractor.extract(from: html)

        let orphan = try XCTUnwrap(segments.first { $0.sourceText == "th" })
        XCTAssertTrue(orphan.isContextlessOrphan, "上标里的 th 是序数后缀，不是词")

        XCTAssertFalse(try XCTUnwrap(segments.first { $0.sourceText == "March" }).isContextlessOrphan)
        XCTAssertFalse(try XCTUnwrap(segments.first { $0.sourceText == "Due on 14" }).isContextlessOrphan)
    }

    // MARK: - 不能误伤：短词但独占一块，是有语境的

    func testStandaloneShortWordsAreNotOrphans() {
        // 这些短词自己就是一句话，必须照常翻译
        for html in ["<button>No</button>", "<p>Save</p>", "<td>Yes</td>", "<a>Next</a>"] {
            let segments = SegmentExtractor.extract(from: html)
            XCTAssertEqual(segments.count, 1, html)
            XCTAssertFalse(segments[0].isContextlessOrphan, "\(html) 不该被判为孤立片段")
        }
    }

    /// 有兄弟节点，但它是**实义词** → 照常翻译。
    /// 判据只看虚词清单，不看长度。
    func testMeaningfulShortWordBesideSiblingsIsNotOrphan() throws {
        // 注意 to 要**独立成一个文本节点**（两边都有标签）才谈得上"被切开"
        let html = "<p>Click <b>Save</b> to <b>continue</b></p>"
        let segments = SegmentExtractor.extract(from: html)

        XCTAssertFalse(try XCTUnwrap(segments.first { $0.sourceText == "Save" }).isContextlessOrphan)
        XCTAssertTrue(try XCTUnwrap(segments.first { $0.sourceText == "to" }).isContextlessOrphan)
    }

    /// 中文没有这种问题 —— CJK 短词单独翻也是对的，不能误伤。
    func testCJKShortWordsAreNeverOrphans() {
        let html = "<p>会议<sup>的</sup>安排</p>"
        for segment in SegmentExtractor.extract(from: html) {
            XCTAssertFalse(segment.isContextlessOrphan, "\(segment.sourceText) 不该被判为孤立片段")
        }
    }

    /// 跨块级容器不算兄弟：两个 `<p>` 里各一个 "to"，各自都是完整语境。
    func testSameWordInDifferentBlocksIsNotOrphan() {
        let html = "<p>to</p><p>to</p>"
        for segment in SegmentExtractor.extract(from: html) {
            XCTAssertFalse(segment.isContextlessOrphan)
        }
    }

    // MARK: - 块级祖先

    func testBlockAncestorIsRecorded() throws {
        let html = "<p>a <b>b</b></p><td>c</td><li>d</li>"
        let segments = SegmentExtractor.extract(from: html)

        XCTAssertEqual(try XCTUnwrap(segments.first { $0.sourceText == "a" }).blockAncestor, "p")
        XCTAssertEqual(try XCTUnwrap(segments.first { $0.sourceText == "b" }).blockAncestor, "p")
        XCTAssertEqual(try XCTUnwrap(segments.first { $0.sourceText == "c" }).blockAncestor, "td")
        XCTAssertEqual(try XCTUnwrap(segments.first { $0.sourceText == "d" }).blockAncestor, "li")
    }

    // MARK: - 端到端：孤立片段保留原文

    /// 模拟"看不到上下文的引擎"：按能力过滤掉孤立片段，其余照翻。
    /// 结果里 ` to ` 必须还在原位，而加粗的时间戳一个字节都没动。
    func testOrphanKeepsOriginalTextWhenSpliced() throws {
        let html = "<p>Meeting from <b>9:00</b> to <b>11:00</b></p>"
        let analysis = EmailAnalysis(
            decoded: DecodedEmail(),
            originalHTML: html,
            usedPlainTextFallback: false,
            segments: SegmentExtractor.extract(from: html)
        )

        // 引擎看不到上下文时，管线只会把这些片段送出去
        let sent = analysis.segments.filter { !$0.isContextlessOrphan }
        XCTAssertFalse(sent.contains { $0.sourceText == "to" })

        let translations = Dictionary(uniqueKeysWithValues: sent.map { ($0.id, "会议从") })
        let spliced = EmailInspector.apply(translations: translations, to: analysis).splicedHTML

        XCTAssertEqual(spliced, "<p>会议从 <b>9:00</b> to <b>11:00</b></p>")
        // 保真保证不受影响
        XCTAssertEqual(
            HTMLTokenizer.skeleton(of: html),
            HTMLTokenizer.skeleton(of: spliced)
        )
    }

    /// 有上下文的引擎（LLM）应该拿到全部片段，包括孤立虚词。
    func testEngineWithFullContextReceivesEverySegment() throws {
        let html = "<p>Meeting from <b>9:00</b> to <b>11:00</b></p>"
        let segments = SegmentExtractor.extract(from: html)

        let all = segments.filter { _ in true }                       // LLM：全给
        let withoutOrphans = segments.filter { !$0.isContextlessOrphan } // Apple：剔除

        XCTAssertTrue(all.contains { $0.sourceText == "to" })
        XCTAssertFalse(withoutOrphans.contains { $0.sourceText == "to" })
        XCTAssertEqual(all.count, withoutOrphans.count + 1)
    }
}
