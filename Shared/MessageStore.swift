import CryptoKit
import EmailCore
import Foundation

/// 一封被捕获下来的邮件（不含正文，只有元数据）。
public struct StoredMessage: Codable, Identifiable, Sendable, Hashable {
    /// 由**原始 MIME 内容**算出的稳定 ID。
    public var id: String
    public var subject: String
    public var from: String
    /// `Date:` 头部解析出来的时间（可能缺失）。
    public var date: Date?
    /// `Message-ID:` 头部，用于展示与去重。
    public var internetMessageID: String?
    public var byteCount: Int
    /// 我们捕获到它的时刻。
    public var capturedAt: Date

    /// 列表里显示的标题。主题为空时退化成发件人。
    public var displayTitle: String {
        subject.isEmpty ? (from.isEmpty ? "(无主题)" : from) : subject
    }
}

/// 用户在 Mail 里点了某封邮件的「翻译」按钮。
public struct PendingTranslationRequest: Codable, Sendable, Equatable {
    public var messageID: String
    public var requestedAt: Date
    /// 每次请求换一个，避免"同一封信连点两次"被误判成没变化。
    public var nonce: String
}

/// 捕获邮件的仓库。
///
/// ## 为什么要按 ID 分开存
///
/// 早先所有邮件都写进同一个 `last-message.eml`，**后一封直接覆盖前一封**。
/// 在会话（来回好几封回复）里这是致命的：Mail 会把线程里每一封都解码一遍，
/// 于是容器 App 拿到的是"最后被解码的那封"，跟用户正在看哪一封**毫无关系**。
/// 实测 200 次调用出现了十几个不同大小 —— 说明确实在多封之间反复覆盖。
///
/// 现在每封邮件一个文件（`messages/<id>.eml` + `<id>.json`），
/// 再靠 banner 的 `context` 把「用户点的是哪一封」精确传出来。
///
/// ## 为什么用"一文件一元数据"而不是一个总索引
///
/// appex 与容器 App 是两个进程。共用一份可变的索引文件会引入读写竞态
/// （appex 正在写、App 正在读）。每封邮件自带元数据、目录即索引，
/// 就没有共享可变状态了。
public enum MessageStore {

    /// 最近捕获的邮件数量上限。会话可能很长，但没必要无限留着。
    public static let maxStoredMessages = 60

    // MARK: - 写入（appex 侧）

    /// 保存一封邮件的原始 MIME，返回它的元数据。
    ///
    /// 同一封邮件重复解码（Mail 会这么干）时是幂等的：ID 由内容决定，
    /// 文件被覆盖成一样的内容，元数据里只更新 `capturedAt`。
    @discardableResult
    public static func save(rawMIME: Data) -> StoredMessage {
        let id = identifier(for: rawMIME)
        let headers = MIMEHeaders.parse(rawMIME)

        let message = StoredMessage(
            id: id,
            subject: MIMEHeaders.decodeRFC2047(MIMEHeaders.value("subject", in: headers) ?? ""),
            from: MIMEHeaders.decodeRFC2047(MIMEHeaders.value("from", in: headers) ?? ""),
            date: parseDate(MIMEHeaders.value("date", in: headers)),
            internetMessageID: MIMEHeaders.value("message-id", in: headers),
            byteCount: rawMIME.count,
            capturedAt: Date()
        )

        // 删除旧版本的 MIME，但保留元数据作为旧横幅 ID 到 Message-ID 的映射。
        // Mail 仍可能显示旧横幅；不能让它因完整版到达而失效。
        if let messageID = message.internetMessageID, !messageID.isEmpty {
            for stale in all()
            where MIMEHeaders.normalizeMessageID(stale.internetMessageID ?? "") == MIMEHeaders.normalizeMessageID(messageID)
                && stale.byteCount < message.byteCount {
                try? FileManager.default.removeItem(at: SharedPaths.messages.appendingPathComponent("\(stale.id).eml"))
            }
        }

        let rawURL = SharedPaths.messages.appendingPathComponent("\(id).eml")
        let metaURL = SharedPaths.messages.appendingPathComponent("\(id).json")

        try? rawMIME.write(to: rawURL, options: .atomic)
        if let data = try? JSONEncoder.messages.encode(message) {
            try? data.write(to: metaURL, options: .atomic)
        }

        pruneIfNeeded()
        return message
    }

    /// 由内容算出的稳定 ID。取 SHA-256 前 16 个十六进制字符，够用且短。
    public static func identifier(for rawMIME: Data) -> String {
        let digest = SHA256.hash(data: rawMIME)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 读取（容器 App 侧）

    public static func rawMessage(id: String) -> Data? {
        try? Data(contentsOf: SharedPaths.messages.appendingPathComponent("\(id).eml"))
    }

    /// 已捕获的邮件，按捕获时间倒序。**同一封只返回一次。**
    ///
    /// ## 为什么必须去重
    ///
    /// Mail 对同一封邮件会回调**两次**：
    /// 1. 先给"信封到了、附件还没下载"的版本 —— 内嵌图片部分是**空的**；
    /// 2. 稍后再给完整版本 —— 图片是真实字节。
    ///
    /// 实测同一封 Message-ID 两次的字节数可以差 725 倍（24KB vs 18MB）。
    /// 如果不去重：
    /// - 下拉列表里同一封邮件会出现两次；
    /// - 更糟的是**可能挑中空壳那一份**，于是内嵌图片全是空白。
    ///
    /// 这里按 `Message-ID` 归组，**保留字节数最多的那份**（最完整）。
    /// 没有 Message-ID 的邮件无法归组，各自保留。
    public static func all() -> [StoredMessage] {
        let stamp: Date? = (try? SharedPaths.messages.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        metadataLock.lock()
        defer { metadataLock.unlock() }

        // 去重 + .eml 存在性过滤的结果也一并缓存：跟随轮询每 0.5 秒经
        // `mostComplete` / `message(matchingInternetMessageID:)` 走到这里，
        // 重算一遍要对每封邮件各做一次 stat（.eml 过滤）+ 归一化去重 + 排序。
        // 失效信号与 `metadata()` 相同 —— 目录 mtime。
        if let stamp, stamp == allCacheStamp {
            return allCache
        }

        let stored = metadataLocked().filter {
            FileManager.default.fileExists(atPath: SharedPaths.messages.appendingPathComponent("\($0.id).eml").path)
        }

        var bestByMessageID: [String: StoredMessage] = [:]
        var ungrouped: [StoredMessage] = []

        for message in stored {
            let key = MIMEHeaders.normalizeMessageID(message.internetMessageID ?? "")
            guard !key.isEmpty else {
                ungrouped.append(message)
                continue
            }
            if let existing = bestByMessageID[key] {
                // 最近读到的小版本也代表这封邮件仍在使用，不能沿用大版本的旧时间。
                let capturedAt = max(existing.capturedAt, message.capturedAt)
                if message.byteCount > existing.byteCount {
                    bestByMessageID[key] = message
                }
                bestByMessageID[key]?.capturedAt = capturedAt
            } else {
                bestByMessageID[key] = message
            }
        }

        let fresh = (Array(bestByMessageID.values) + ungrouped)
            .sorted { $0.capturedAt > $1.capturedAt }

        if let stamp {
            allCache = fresh
            allCacheStamp = stamp
        }
        return fresh
    }

    /// 内容版本 ID 可能不在去重后的列表中；先读取它的身份，再定位可用版本。
    public static func message(id: String, internetMessageID: String? = nil) -> StoredMessage? {
        let exact = metadata().first { $0.id == id }
        if let identity = exact?.internetMessageID ?? internetMessageID,
           let best = message(matchingInternetMessageID: identity) {
            return best
        }
        guard let exact, rawMessage(id: exact.id) != nil else { return nil }
        return exact
    }

    private static func metadata() -> [StoredMessage] {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        return metadataLocked()
    }

    /// `metadata()` 与 `all()` 共用一把非重入锁，`all()` 持锁期间要走这个
    /// 不加锁的版本，否则自锁死锁（NSLock 不可重入）。
    private static func metadataLocked() -> [StoredMessage] {
        let directory = SharedPaths.messages
        let stamp: Date? = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        // 目录条目没变 → 直接用上一份结果。跟随轮询每 0.5 秒都会经
        // `mostComplete` / `message(matchingInternetMessageID:)` 走到这里，
        // 不缓存的话每次都是「readdir + 逐文件 open/decode + 逐 .eml fileExists」
        // 的全量磁盘扫描（几十封邮件 = 上百次文件系统调用），而且发生在主线程
        // 上——磁盘一抖就是一次滚动卡顿。
        if let stamp, stamp == metadataCacheStamp {
            return metadataCache
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder.messages
        let fresh = entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StoredMessage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(StoredMessage.self, from: data)
            }

        // 失效信号是**目录 mtime**：所有写入都走 atomic（临时文件 + rename）
        // 或删除，目录条目一变 mtime 必变（appex 在另一个进程里写也一样）。
        // 生产代码没有原地改写 .json 的路径。
        if let stamp {
            metadataCache = fresh
            metadataCacheStamp = stamp
        }
        return fresh
    }

    /// `metadata()` 的目录 mtime 守卫缓存与互斥锁（appex 与容器 App 都会调用，
    /// 且轮询让它在主线程上高频出现，必须线程安全）。
    private static var metadataCache: [StoredMessage] = []
    private static var metadataCacheStamp: Date?
    /// `all()` 去重结果的缓存 —— 与 `metadata()` 共用一把锁、同一个失效信号。
    private static var allCache: [StoredMessage] = []
    private static var allCacheStamp: Date?
    private static let metadataLock = NSLock()

    /// 按 Message-ID 找一封邮件（比较前会归一化尖括号）。
    ///
    /// 用途：Mail 那边告诉我们"当前选中的是 <xxx@yyy>"，用它对上号。
    public static func message(matchingInternetMessageID raw: String) -> StoredMessage? {
        let target = MIMEHeaders.normalizeMessageID(raw)
        guard !target.isEmpty else { return nil }
        return all().first {
            MIMEHeaders.normalizeMessageID($0.internetMessageID ?? "") == target
        }
    }

    /// 同一封邮件里，哪一份最完整（字节数最大）。
    ///
    /// 界面用它来判断"我现在显示的这份是不是空壳，要不要换成完整的"。
    public static func mostComplete(forInternetMessageID internetMessageID: String) -> StoredMessage? {
        all()
            .filter { $0.internetMessageID == internetMessageID }
            .max { $0.byteCount < $1.byteCount }
    }

    public static func mostRecent() -> StoredMessage? {
        all().first
    }

    // MARK: - 待处理请求

    /// appex 在被点击 banner 时调用：告诉容器 App「用户要翻这一封」。
    public static func writePendingRequest(messageID: String) {
        let request = PendingTranslationRequest(
            messageID: messageID,
            requestedAt: Date(),
            nonce: UUID().uuidString
        )
        guard let data = try? JSONEncoder.messages.encode(request) else { return }
        try? data.write(to: SharedPaths.pendingRequest, options: .atomic)
    }

    /// 处理完之后把请求文件删掉。
    ///
    /// 请求是**一次性**的：留着它，每次冷启动（现在关窗即退出，冷启动很频繁）
    /// 都会把上一次点过的邮件再"处理"一遍，跟本次真正的目标抢着载入。
    public static func clearPendingRequest() {
        try? FileManager.default.removeItem(at: SharedPaths.pendingRequest)
    }

    public static func readPendingRequest() -> PendingTranslationRequest? {
        guard let data = try? Data(contentsOf: SharedPaths.pendingRequest) else { return nil }
        return try? JSONDecoder.messages.decode(PendingTranslationRequest.self, from: data)
    }

    // MARK: - 私有

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // RFC 5322 日期，形态很多；两种 formatter 覆盖绝大多数情况
        for formatter in [DateFormatter.rfc5322, DateFormatter.rfc5322Fallback] {
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// 删掉一封邮件的两个文件（.eml 与 .json）。
    private static func removeFiles(id: String) {
        for ext in ["eml", "json"] {
            try? FileManager.default.removeItem(
                at: SharedPaths.messages.appendingPathComponent("\(id).\(ext)")
            )
        }
    }

    /// 超出上限就删掉最旧的（连同 .eml 和 .json）。
    private static func pruneIfNeeded() {
        let messages = all()
        guard messages.count > maxStoredMessages else { return }

        for message in messages[maxStoredMessages...] {
            let identity = MIMEHeaders.normalizeMessageID(message.internetMessageID ?? "")
            for version in metadata() where version.id == message.id ||
                (!identity.isEmpty && MIMEHeaders.normalizeMessageID(version.internetMessageID ?? "") == identity) {
                removeFiles(id: version.id)
            }
        }
    }
}

// MARK: - 编解码器

private extension JSONEncoder {
    static var messages: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var messages: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension DateFormatter {
    static var rfc5322: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter
    }

    static var rfc5322Fallback: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy HH:mm:ss Z"
        return formatter
    }
}
