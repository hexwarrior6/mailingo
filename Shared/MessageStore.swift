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

        // 同一封邮件的旧版本（通常是"附件未下载"的空壳）直接删掉，
        // 免得目录里越积越多。all() 已经会去重，这里是为了不占磁盘。
        if let messageID = message.internetMessageID, !messageID.isEmpty {
            for stale in all()
            where stale.internetMessageID == messageID && stale.byteCount < message.byteCount {
                removeFiles(id: stale.id)
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
        let directory = SharedPaths.messages
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder.messages
        let stored = entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StoredMessage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(StoredMessage.self, from: data)
            }

        var bestByMessageID: [String: StoredMessage] = [:]
        var ungrouped: [StoredMessage] = []

        for message in stored {
            guard let key = message.internetMessageID, !key.isEmpty else {
                ungrouped.append(message)
                continue
            }
            if let existing = bestByMessageID[key] {
                if message.byteCount > existing.byteCount {
                    bestByMessageID[key] = message
                }
            } else {
                bestByMessageID[key] = message
            }
        }

        return (Array(bestByMessageID.values) + ungrouped)
            .sorted { $0.capturedAt > $1.capturedAt }
    }

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
            removeFiles(id: message.id)
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
