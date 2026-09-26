import EmailCore
import Foundation
import Translation
import XCTest

@testable import TranslationCore

/// TranslationCore 的单元测试。
///
/// 这里**不调用 Apple Translation 本身** —— 那是系统服务，依赖语言包是否安装、
/// 还可能弹下载确认框，不适合放进自动化测试。
/// 所以：能纯函数化的逻辑（分批、按 id 装配、语言检测）在这里覆盖，
/// 真实引擎的行为走 App 内的自检（见 docs 与 `TranslationSelfTest`）。
final class TranslationCoreTests: XCTestCase {

    // MARK: - 分批

    func testBatchesSplitsEvenlyAndKeepsOrder() {
        let segments = makeSegments(count: 5)
        let batches = AppleTranslationEngine.batches(segments, size: 2)

        XCTAssertEqual(batches.map(\.count), [2, 2, 1])
        // 顺序必须保持，否则译文会错位
        XCTAssertEqual(batches.flatMap { $0.map(\.id) }, [0, 1, 2, 3, 4])
    }

    func testBatchesHandlesEmptyAndOversizedBatchSize() {
        XCTAssertTrue(AppleTranslationEngine.batches([], size: 10).isEmpty)

        let segments = makeSegments(count: 3)
        XCTAssertEqual(AppleTranslationEngine.batches(segments, size: 100).map(\.count), [3])
        // size <= 0 是非法输入，不该崩、也不该丢片段
        XCTAssertEqual(AppleTranslationEngine.batches(segments, size: 0).flatMap { $0.map(\.id) }, [0, 1, 2])
    }

    // MARK: - 按 id 装配（不依赖返回顺序）

    func testAssembleIsKeyedByIdNotByOrder() {
        let segments = makeSegments(count: 3)
        // 故意打乱：引擎返回顺序不可信
        let collected = [2: "三", 0: "一", 1: "二"]

        let result = AppleTranslationEngine.assemble(segments: segments, collected: collected)

        XCTAssertEqual(result.map(\.id), [0, 1, 2], "结果顺序必须跟入参一致")
        XCTAssertEqual(result.map(\.targetText), ["一", "二", "三"])
    }

    /// 引擎漏回某些片段时，**回退成原文**而不是丢掉 —— 丢一段等于邮件里少一句话。
    func testAssembleFallsBackToSourceTextForMissingSegments() {
        let segments = makeSegments(count: 3)
        let result = AppleTranslationEngine.assemble(segments: segments, collected: [1: "二"])

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.targetText), ["原文 0", "二", "原文 2"])
    }

    // MARK: - 语言检测

    func testDetectsEnglish() {
        let text = """
        Your weekly digest is here. We shipped three new features and fixed twelve bugs this week. \
        Please review the changelog before upgrading your account.
        """
        let language = LanguageDetector.detect(inText: text)
        XCTAssertEqual(language?.languageCode?.identifier, "en")
    }

    func testDetectsSimplifiedChinese() {
        let text = "您好，您的订单已经发货，预计三天内送达。如有问题请联系客服，谢谢您的支持与理解。"
        let language = LanguageDetector.detect(inText: text)
        XCTAssertEqual(language?.languageCode?.identifier, "zh")
    }

    /// 太短的样本宁可不猜 —— 猜错源语言比不猜更糟。
    func testVeryShortTextIsNotGuessed() {
        XCTAssertNil(LanguageDetector.detect(inText: "OK"))
        XCTAssertNil(LanguageDetector.detect(inText: ""))
    }

    func testDetectsFromSegmentsUsingMultipleSamples() {
        let segments = [
            makeSegment(id: 0, text: "OK"),                       // 单独看无法判断
            makeSegment(id: 1, text: "Please confirm your shipping address so we can dispatch the parcel."),
            makeSegment(id: 2, text: "Thank you for shopping with us.")
        ]
        XCTAssertEqual(LanguageDetector.detect(in: segments)?.languageCode?.identifier, "en")
    }

    /// 回归：真实邮件里富链接卡片的标题 `github.com` 混进检测样本后，
    /// 整封英文邮件曾被识别成挪威语（nb，0.362 刚好越过 0.35 门槛），
    /// 而系统翻译不支持 nb → zh，直接报"不支持的语言对"。
    /// 修法在 SegmentExtractor（裸域名不成为片段）；这里从原始 MIME 一路
    /// 走到检测，钉住端到端的结果 —— 样本里没有裸域名，判定必须还是英文。
    func testDetectionSurvivesRichLinkDomainCaptions() throws {
        let eml = """
        From: Ira Kumar <ira@example.com>
        To: Yuhao <yuhao@example.com>
        Subject: Re: Nightingale Messenger
        Content-Type: text/html; charset=utf-8

        <html><body>
        <p>[Alert: Non-NTU Email] Be cautious before clicking any link or attachment.</p>
        <div><a href="https://github.com/Ntngale/messenger/invitations">github.com</a></div>
        <p>Try again.</p>
        <p>Determine if this is helpful for build evaluation:</p>
        <p>Introducing Synthetic Hospital: an open, fully synthetic longitudinal EHR benchmark with verifiable ground truth!</p>
        <p>1,268 patients, 5,602 encounters, zero PHI. Physicians could not reliably distinguish its charts from real ones.</p>
        </body></html>
        """
        let analysis = try EmailInspector.analyze(rawMessage: Data(eml.utf8))
        XCTAssertFalse(analysis.segments.contains { $0.sourceText == "github.com" },
                       "裸域名被当成片段送进了管线")
        XCTAssertEqual(LanguageDetector.detect(in: analysis.segments)?.languageCode?.identifier, "en")
    }

    // MARK: - 引擎契约（用假引擎验证协议本身）

    func testFakeEnginesHonourTheProtocolContract() async throws {
        for engine in [AnyEngine(MarkerTranslationEngine()), AnyEngine(IdentityTranslationEngine())] {
            let segments = makeSegments(count: 4)
            let progress = ProgressRecorder()

            let result = try await engine.translate(
                segments: segments,
                sourceLanguage: nil,
                targetLanguage: TranslationLanguages.simplifiedChinese,
                progress: { done, total in progress.record(done: done, total: total) }
            )

            XCTAssertEqual(result.map(\.id), segments.map(\.id), "\(engine.displayName)：id 必须一一对应")
            XCTAssertEqual(
                progress.snapshots.map(\.total), Array(repeating: 4, count: 4),
                "\(engine.displayName)：total 应始终是片段总数"
            )
            XCTAssertEqual(progress.snapshots.map(\.done), [1, 2, 3, 4], "\(engine.displayName)：进度应单调递增")
        }
    }

    func testFailingEngineSurfacesError() async {
        let engine = FailingTranslationEngine(message: "网络炸了")
        do {
            _ = try await engine.translate(
                segments: makeSegments(count: 1),
                sourceLanguage: nil,
                targetLanguage: TranslationLanguages.simplifiedChinese
            )
            XCTFail("应该抛错")
        } catch let error as TranslationEngineError {
            XCTAssertTrue(error.description.contains("网络炸了"), error.description)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - 配置触发（这是一个真实踩过的坑，用测试钉住）

    /// **先证实这个坑真的存在**：每次新建 `Configuration` 再 `invalidate()`，
    /// 得到的配置是**彼此相等**的 —— 因为它们都停在 version 1。
    ///
    /// 如果这条断言某天开始失败（Apple 改了 Configuration 的相等性或
    /// invalidate 的语义），那说明下面那条"必须复用同一实例"的约束可以放宽，
    /// 这里会第一时间告诉我们。
    func testFreshConfigurationEachTimeProducesEqualConfigurations() {
        let target = TranslationLanguages.simplifiedChinese

        var first = TranslationSession.Configuration(source: nil, target: target)
        first.invalidate()
        var second = TranslationSession.Configuration(source: nil, target: target)
        second.invalidate()

        XCTAssertEqual(
            first, second,
            """
            每次新建 Configuration 再 invalidate 竟然不相等了 —— \
            意味着 Apple 改了语义。此时可以放宽 TranslationConfigurationSequencer \
            的约束，并重新评估 broker 的设计。
            """
        )
    }

    /// 生产代码用的方式：复用同一个实例反复 invalidate，
    /// 相邻两次配置**必须**互不相等，否则 `.translationTask` 不会重新触发。
    func testReusedSequencerAlwaysProducesDistinctConsecutiveConfigurations() {
        var sequencer = TranslationConfigurationSequencer()
        let target = TranslationLanguages.simplifiedChinese

        var produced: [TranslationSession.Configuration] = []
        for _ in 0..<6 {
            produced.append(sequencer.next(source: nil, target: target))
        }

        for index in 1..<produced.count {
            XCTAssertNotEqual(
                produced[index - 1], produced[index],
                "第 \(index) 次与上一次配置相等 —— .translationTask 不会重新触发，第二个作业会一直等到超时"
            )
        }

        // 语言对变化时也必须产出不同的配置
        let other = sequencer.next(source: nil, target: Locale.Language(identifier: "ja"))
        XCTAssertNotEqual(produced.last, other)
    }

    // MARK: - 辅助

    private func makeSegments(count: Int) -> [TranslationSegment] {
        (0..<count).map { makeSegment(id: $0, text: "原文 \($0)") }
    }

    private func makeSegment(id: Int, text: String) -> TranslationSegment {
        let html = "<p>\(text)</p>"
        let range = html.range(of: text)!
        return TranslationSegment(
            id: id,
            kind: .paragraph,
            sourceText: text,
            range: range,
            coreRange: range,
            ancestorTags: ["p"]
        )
    }
}

/// 让不同类型的引擎能放进同一个数组里跑契约测试。
private struct AnyEngine: TranslationEngine {
    private let wrapped: any TranslationEngine

    init(_ wrapped: any TranslationEngine) { self.wrapped = wrapped }

    var id: String { wrapped.id }
    var displayName: String { wrapped.displayName }

    func availability(source: Locale.Language?, target: Locale.Language) async -> TranslationAvailability {
        await wrapped.availability(source: source, target: target)
    }

    func translate(
        segments: [TranslationSegment],
        sourceLanguage: Locale.Language?,
        targetLanguage: Locale.Language,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [TranslatedSegment] {
        try await wrapped.translate(
            segments: segments,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            progress: progress
        )
    }
}

/// 收集 progress 回调。回调可能在任意线程触发，所以加锁。
private final class ProgressRecorder: @unchecked Sendable {
    struct Snapshot { let done: Int; let total: Int }

    private let lock = NSLock()
    private var storage: [Snapshot] = []

    var snapshots: [Snapshot] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(done: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        storage.append(Snapshot(done: done, total: total))
    }
}
