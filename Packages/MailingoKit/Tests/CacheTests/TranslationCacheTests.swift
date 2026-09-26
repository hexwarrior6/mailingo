import Foundation
import XCTest

@testable import Cache

/// 翻译缓存。重点是**两条用户可配置的清理规则**。
///
/// 注意：`XCTAssert*` 的参数是 autoclosure，**里面不能写 `await`**，
/// 所以统一先把值取出来再断言。
final class TranslationCacheTests: XCTestCase {

    private var directory: URL!
    private var cache: TranslationCache!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailingo-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = TranslationCache(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 辅助

    private func key(
        message: String = "<a@b>",
        source: String? = nil,
        language: String = "zh-Hans",
        engine: String = "apple.translation.v1",
        pipeline: Int = CacheKey.currentPipelineVersion
    ) -> CacheKey {
        CacheKey(messageKey: message, sourceLanguage: source, targetLanguage: language, engineID: engine, pipelineVersion: pipeline)
    }

    private func entryCount() async -> Int {
        await cache.statistics().entryCount
    }

    private func totalBytes() async -> Int {
        await cache.statistics().totalBytes
    }

    private func storedFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func backdate(_ file: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    // MARK: - 基本读写

    func testStoreThenLookupHits() async {
        await cache.store(key(), sourceHash: "hash-1", translations: [0: "你好", 1: "世界"])

        let hit = await cache.lookup(key(), sourceHash: "hash-1")
        XCTAssertEqual(hit, [0: "你好", 1: "世界"])
    }

    func testLookupMissesWhenNothingStored() async {
        let hit = await cache.lookup(key(), sourceHash: "hash-1")
        XCTAssertNil(hit)
    }

    /// 内容变了（HTML 哈希不同）必须重翻，不能拿旧译文凑。
    func testLookupMissesWhenSourceHashDiffers() async {
        await cache.store(key(), sourceHash: "hash-1", translations: [0: "你好"])

        let hit = await cache.lookup(key(), sourceHash: "hash-2")
        XCTAssertNil(hit)
    }

    /// 换引擎不能复用旧引擎的译文（质量与术语都不同）。
    func testDifferentEngineIsADifferentEntry() async {
        await cache.store(key(engine: "apple.translation.v1"), sourceHash: "h", translations: [0: "苹果"])

        let hit = await cache.lookup(key(engine: "deepseek.v1"), sourceHash: "h")
        XCTAssertNil(hit)
    }

    /// 切片算法版本一变，旧缓存必须失效 —— 否则段 id 对不上会错位。
    func testPipelineVersionInvalidatesCache() async {
        await cache.store(key(pipeline: 1), sourceHash: "h", translations: [0: "旧"])

        let hit = await cache.lookup(key(pipeline: 2), sourceHash: "h")
        XCTAssertNil(hit)
    }

    func testDifferentLanguageIsADifferentEntry() async {
        await cache.store(key(language: "zh-Hans"), sourceHash: "h", translations: [0: "中文"])

        let hit = await cache.lookup(key(language: "ja"), sourceHash: "h")
        XCTAssertNil(hit)
    }

    /// 钉住的源语言要参与缓存键：同一封邮件，"自动检测"和"钉住英语"是两条缓存 ——
    /// 自动检测会出错，钉住本身就是纠正手段，两种结果不能互相覆盖。
    func testPinnedSourceLanguageIsADifferentEntry() async {
        await cache.store(key(source: "en"), sourceHash: "h", translations: [0: "钉住英语的结果"])

        let pinned = await cache.lookup(key(source: "en"), sourceHash: "h")
        let auto = await cache.lookup(key(source: nil), sourceHash: "h")
        let other = await cache.lookup(key(source: "fr"), sourceHash: "h")

        XCTAssertEqual(pinned, [0: "钉住英语的结果"])
        XCTAssertNil(auto, "自动检测的缓存不该命中钉住英语的条目")
        XCTAssertNil(other, "钉别的语言也不该命中")
    }

    func testStoreOverwritesExistingEntry() async {
        await cache.store(key(), sourceHash: "h1", translations: [0: "第一次"])
        await cache.store(key(), sourceHash: "h2", translations: [0: "第二次"])

        let newest = await cache.lookup(key(), sourceHash: "h2")
        let stale = await cache.lookup(key(), sourceHash: "h1")
        let count = await entryCount()

        XCTAssertEqual(newest, [0: "第二次"])
        XCTAssertNil(stale)
        XCTAssertEqual(count, 1, "同一键不该留下两份")
    }

    // MARK: - 统计

    func testStatisticsCountsEntriesAndBytes() async {
        for index in 0..<3 {
            await cache.store(key(message: "<m\(index)@x>"), sourceHash: "h", translations: [0: "你好"])
        }

        let stats = await cache.statistics()
        XCTAssertEqual(stats.entryCount, 3)
        XCTAssertGreaterThan(stats.totalBytes, 0)
        XCTAssertNotNil(stats.oldestAccess)
    }

    /// 查一次要刷新"最近使用时间"，否则常用的缓存会被当成旧的清掉。
    func testLookupRefreshesLastAccessTime() async throws {
        await cache.store(key(), sourceHash: "h", translations: [0: "你好"])

        let file = try XCTUnwrap(try storedFiles().first)
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86_400)
        try backdate(file, to: tenDaysAgo)

        let before = await cache.statistics().oldestAccess
        XCTAssertEqual(try XCTUnwrap(before).timeIntervalSince1970, tenDaysAgo.timeIntervalSince1970, accuracy: 2)

        _ = await cache.lookup(key(), sourceHash: "h")

        let after = await cache.statistics().oldestAccess
        XCTAssertGreaterThan(try XCTUnwrap(after), Date().addingTimeInterval(-60), "查过之后应该算「刚用过」")
    }

    // MARK: - 清理规则 ①：多少天以前

    func testPurgeRemovesEntriesOlderThanMaxAge() async throws {
        await cache.store(key(message: "<old@x>"), sourceHash: "h", translations: [0: "旧"])
        await cache.store(key(message: "<new@x>"), sourceHash: "h", translations: [0: "新"])

        // 靠内容认出"旧"那一份，把它伪装成 40 天前用过
        for file in try storedFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("旧") {
                try backdate(file, to: Date().addingTimeInterval(-40 * 86_400))
            }
        }

        let result = await cache.purge(policy: CachePolicy(maxAgeDays: 30, maxSizeMB: 0))

        let old = await cache.lookup(key(message: "<old@x>"), sourceHash: "h")
        let new = await cache.lookup(key(message: "<new@x>"), sourceHash: "h")
        let count = await entryCount()

        XCTAssertEqual(result.removedByAge, 1)
        XCTAssertEqual(count, 1)
        XCTAssertNil(old)
        XCTAssertNotNil(new)
    }

    /// `maxAgeDays = 0` 表示不按时间清理。
    func testZeroMaxAgeMeansUnlimited() async throws {
        await cache.store(key(), sourceHash: "h", translations: [0: "你好"])
        let file = try XCTUnwrap(try storedFiles().first)
        try backdate(file, to: Date().addingTimeInterval(-3650 * 86_400))

        let result = await cache.purge(policy: CachePolicy(maxAgeDays: 0, maxSizeMB: 0))

        XCTAssertEqual(result.removedByAge, 0)
        let count = await entryCount()
        XCTAssertEqual(count, 1, "0 应当表示不限，不能把十年老的也删了")
    }

    // MARK: - 清理规则 ②：多少 MB 以上

    /// 超出大小上限时，从**最久未用**的开始淘汰，直到降到上限以内。
    func testPurgeRemovesLeastRecentlyUsedWhenOverSizeLimit() async throws {
        // 每条塞一份较大的译文，凑到 1MB 以上
        let padding = String(repeating: "译", count: 3000)
        let count = 260
        for index in 0..<count {
            await cache.store(key(message: "<m\(index)@x>"), sourceHash: "h", translations: [0: padding])
        }

        let before = await cache.statistics()
        XCTAssertGreaterThan(before.totalBytes, 1_048_576, "测试前提：总量要超过 1MB")

        // 让 mtime 严格递增 —— index 越小越旧
        let base = Date().addingTimeInterval(-10_000)
        for file in try storedFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard let start = text.range(of: "<m"),
                  let end = text[start.upperBound...].firstIndex(of: "@"),
                  let index = Int(text[start.upperBound..<end]) else { continue }
            try backdate(file, to: base.addingTimeInterval(Double(index)))
        }

        let result = await cache.purge(policy: CachePolicy(maxAgeDays: 0, maxSizeMB: 1))

        let after = await cache.statistics()
        let oldest = await cache.lookup(key(message: "<m0@x>"), sourceHash: "h")
        let newest = await cache.lookup(key(message: "<m\(count - 1)@x>"), sourceHash: "h")

        XCTAssertGreaterThan(result.removedBySize, 0)
        XCTAssertLessThanOrEqual(after.totalBytes, 1_048_576, "清理后应当降到上限以内")
        XCTAssertLessThan(after.entryCount, before.entryCount)
        XCTAssertNil(oldest, "最旧的应当被淘汰")
        XCTAssertNotNil(newest, "最新的应当留下")
    }

    /// `maxSizeMB = 0` 表示不限制大小。
    func testZeroMaxSizeMeansUnlimited() async {
        await cache.store(key(), sourceHash: "h", translations: [0: String(repeating: "x", count: 5000)])

        let result = await cache.purge(policy: CachePolicy(maxAgeDays: 0, maxSizeMB: 0))

        XCTAssertEqual(result.removedBySize, 0)
        let count = await entryCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - 清空

    func testRemoveAll() async {
        for index in 0..<5 {
            await cache.store(key(message: "<m\(index)@x>"), sourceHash: "h", translations: [0: "你好"])
        }
        let before = await entryCount()
        XCTAssertEqual(before, 5)

        let removed = await cache.removeAll()

        XCTAssertEqual(removed, 5)
        let count = await entryCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - 内容指纹

    /// 同一份 HTML 必须得到同一个哈希；改一个字符就不同。
    func testContentHashIsStableAndSensitive() {
        let html = "<p>Hello</p>"
        XCTAssertEqual(TranslationCache.contentHash(of: html), TranslationCache.contentHash(of: html))
        XCTAssertNotEqual(
            TranslationCache.contentHash(of: html),
            TranslationCache.contentHash(of: "<p>Hello!</p>")
        )
    }

    /// 真实场景：Mail 分两次交付同一封邮件，**HTML 逐字节相同**
    /// （差别只在附件图片有没有下载），所以完整版到达时应当命中空壳版的缓存。
    func testShellAndFullDeliveryShareTheSameCacheEntry() async {
        let html = "<p>Campus recruitment info session</p>"   // 两次交付的 HTML 一样
        let hash = TranslationCache.contentHash(of: html)
        let messageKey = "SG2PR01MB4097@apcprd01.prod.exchangelabs.com"

        // 空壳版：附件还没下载，但 HTML 已经可以翻
        await cache.store(key(message: messageKey), sourceHash: hash, translations: [0: "校园招聘宣讲会"])

        // 完整版到达：同一个 Message-ID、同一份 HTML → 命中，不必重翻
        let hit = await cache.lookup(key(message: messageKey), sourceHash: hash)

        XCTAssertEqual(hit, [0: "校园招聘宣讲会"])
        let count = await entryCount()
        XCTAssertEqual(count, 1)
    }

    /// 总量统计用的是真实文件大小，不是估算。
    func testTotalBytesReflectsActualFiles() async throws {
        await cache.store(key(), sourceHash: "h", translations: [0: String(repeating: "字", count: 2000)])

        let onDisk = try storedFiles().reduce(0) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return total + size
        }
        let reported = await totalBytes()

        XCTAssertEqual(reported, onDisk)
    }
}
