import CryptoKit
import Foundation

/// 缓存的键。
///
/// ## 为什么 `messageKey` 和 `sourceHash` 要分开
///
/// - `messageKey` 是**身份**：优先用归一化后的 Message-ID，
///   这样同一封邮件（Mail 会分两次交付：先空壳、后完整）落到同一个键上。
/// - `sourceHash` 是**内容指纹**：真正被翻译的是 HTML，只有 HTML 没变，
///   之前的译文才能复用。
///
/// 实测空壳版与完整版的 HTML **逐字节相同**（差别只在附件的图片数据），
/// 所以按 HTML 哈希做校验时，完整版到达可以直接命中空壳版算出来的缓存，
/// 不会白翻一遍。
public struct CacheKey: Hashable, Sendable {
    public let messageKey: String
    /// 源语言。`nil` = 自动检测。
    ///
    /// 单独成键：同一封邮件，"自动检测出的源"和"用户钉住的源"可能不同
    /// （自动检测会出错，钉住本身就是纠正手段），两种结果不能互相覆盖。
    public let sourceLanguage: String?
    public let targetLanguage: String
    public let engineID: String
    /// 分段/切片逻辑的版本。算法一变，旧缓存必须失效。
    public let pipelineVersion: Int

    public init(
        messageKey: String,
        sourceLanguage: String? = nil,
        targetLanguage: String,
        engineID: String,
        pipelineVersion: Int
    ) {
        self.messageKey = messageKey
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.engineID = engineID
        self.pipelineVersion = pipelineVersion
    }

    /// 当前切片管线的版本。改了 SegmentExtractor / HTMLSplicer 就要 +1。
    /// v2：裸域名不再作为片段（此前一行 `github.com` 会污染语言检测，见 SegmentExtractor）。
    public static let currentPipelineVersion = 2
}

/// 缓存的清理策略（用户可在设置里改）。
public struct CachePolicy: Sendable, Equatable {
    /// 多少天没用过就清掉。0 表示不限。
    public var maxAgeDays: Int
    /// 总大小上限（MB）。0 表示不限。
    public var maxSizeMB: Int

    public init(maxAgeDays: Int = 30, maxSizeMB: Int = 200) {
        self.maxAgeDays = maxAgeDays
        self.maxSizeMB = maxSizeMB
    }

    public static let `default` = CachePolicy()

    public var isUnlimitedAge: Bool { maxAgeDays <= 0 }
    public var isUnlimitedSize: Bool { maxSizeMB <= 0 }
}

public struct CacheStatistics: Sendable, Equatable {
    public var entryCount: Int
    public var totalBytes: Int
    public var oldestAccess: Date?

    public init(entryCount: Int = 0, totalBytes: Int = 0, oldestAccess: Date? = nil) {
        self.entryCount = entryCount
        self.totalBytes = totalBytes
        self.oldestAccess = oldestAccess
    }

    public var totalMegabytes: Double { Double(totalBytes) / 1_048_576 }
}

public struct CachePurgeResult: Sendable, Equatable {
    public var removedByAge: Int
    public var removedBySize: Int
    public var freedBytes: Int

    public init(removedByAge: Int = 0, removedBySize: Int = 0, freedBytes: Int = 0) {
        self.removedByAge = removedByAge
        self.removedBySize = removedBySize
        self.freedBytes = freedBytes
    }

    public var removedTotal: Int { removedByAge + removedBySize }
}

/// 翻译缓存。
///
/// 一条缓存一个 JSON 文件，文件名是缓存键的哈希 —— 这样清理时可以直接
/// 靠文件系统的 mtime 与大小来统计，不需要额外维护索引（索引本身就是
/// 一份需要同步的可变状态）。
public actor TranslationCache {

    public static let shared = TranslationCache()

    /// 单条缓存文件的结构。
    private struct Entry: Codable {
        var sourceHash: String
        /// 段 id → 译文。**用字符串键**：`[Int: String]` 会被 JSONEncoder
        /// 编成「键值交替的数组」，可读性和兼容性都差。
        var translations: [String: String]
        var createdAt: Date
        var lastAccessedAt: Date
    }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL = TranslationCache.defaultDirectory) {
        self.directory = directory

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 默认位置：`~/Library/Caches/Mailingo/translations`。
    ///
    /// 放在 Caches 目录而不是 Application Support：系统在磁盘紧张时可以回收它，
    /// 而且它本来就是可以随时重建的数据。
    public static var defaultDirectory: URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Mailingo/translations", isDirectory: true)
    }

    /// 被翻译内容的指纹（对 HTML 本身算，而不是整封 MIME）。
    ///
    /// 实测 Mail 分两次交付的同一封邮件（先空壳、后完整）**HTML 逐字节相同**，
    /// 差别只在附件的图片数据。所以对 HTML 算哈希，完整版到达时能直接命中
    /// 空壳版算出来的缓存，不会白翻一遍。
    public static func contentHash(of html: String) -> String {
        SHA256.hash(data: Data(html.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - 读

    /// 查缓存。`sourceHash` 必须与写入时一致才算命中。
    public func lookup(_ key: CacheKey, sourceHash: String) -> [Int: String]? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? decoder.decode(Entry.self, from: data),
              entry.sourceHash == sourceHash else {
            return nil
        }

        // 更新访问时间（LRU 与"多久没用过"都靠它）
        try? touch(url)

        return Dictionary(
            uniqueKeysWithValues: entry.translations.compactMap { key, value in
                Int(key).map { ($0, value) }
            }
        )
    }

    // MARK: - 写

    public func store(_ key: CacheKey, sourceHash: String, translations: [Int: String]) {
        let existing = (try? Data(contentsOf: fileURL(for: key)))
            .flatMap { try? decoder.decode(Entry.self, from: $0) }

        let entry = Entry(
            sourceHash: sourceHash,
            translations: Dictionary(
                uniqueKeysWithValues: translations.map { (String($0.key), $0.value) }
            ),
            createdAt: existing?.createdAt ?? Date(),
            lastAccessedAt: Date()
        )

        guard let data = try? encoder.encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    // MARK: - 统计

    public func statistics() -> CacheStatistics {
        var stats = CacheStatistics()
        // 注意括号：`try? entries() ?? []` 会被解析成 `try? (entries() ?? [])`，
        // 而 entries() 是 throws 的，那样根本编不过。
        for (_, attributes, _) in (try? entries()) ?? [] {
            stats.entryCount += 1
            stats.totalBytes += (attributes[.size] as? Int) ?? 0
            if let modified = attributes[.modificationDate] as? Date {
                if stats.oldestAccess == nil || modified < stats.oldestAccess! {
                    stats.oldestAccess = modified
                }
            }
        }
        return stats
    }

    // MARK: - 清理

    /// 按策略清理：先按"多久没用过"，再按总大小淘汰最久未用的。
    @discardableResult
    public func purge(policy: CachePolicy) -> CachePurgeResult {
        var result = CachePurgeResult()
        let all = (try? entries()) ?? []

        // ① 按时间：mtime 就是最近访问时间
        var survivors: [(url: URL, size: Int, modified: Date)] = []
        let deadline = policy.isUnlimitedAge
            ? nil
            : Date().addingTimeInterval(-Double(policy.maxAgeDays) * 86_400)

        for (url, attributes, modified) in all {
            if let deadline, modified < deadline {
                let size = (attributes[.size] as? Int) ?? 0
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    result.removedByAge += 1
                    result.freedBytes += size
                }
            } else {
                survivors.append((url, (attributes[.size] as? Int) ?? 0, modified))
            }
        }

        // ② 按大小：从最久未用的开始删，直到降到上限以内
        guard !policy.isUnlimitedSize else { return result }
        let limit = policy.maxSizeMB * 1_048_576
        var total = survivors.reduce(0) { $0 + $1.size }
        guard total > limit else { return result }

        for entry in survivors.sorted(by: { $0.modified < $1.modified }) {
            guard total > limit else { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
                result.removedBySize += 1
                result.freedBytes += entry.size
            }
        }

        return result
    }

    /// 清空全部缓存。
    @discardableResult
    public func removeAll() -> Int {
        let all = (try? entries()) ?? []
        var removed = 0
        for (url, _, _) in all where (try? FileManager.default.removeItem(at: url)) != nil {
            removed += 1
        }
        return removed
    }

    // MARK: - 私有

    private func fileURL(for key: CacheKey) -> URL {
        let raw = "\(key.messageKey)\u{1F}\(key.sourceLanguage ?? "auto")\u{1F}\(key.targetLanguage)\u{1F}\(key.engineID)\u{1F}\(key.pipelineVersion)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }

    /// 每个缓存文件连同它的属性。
    private func entries() throws -> [(URL, [FileAttributeKey: Any], Date)] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil
            }
            let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
            return (url, attributes, modified)
        }
    }

    /// 把文件的修改时间推到现在 —— 它就是"最近使用时间"。
    private func touch(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
