import Foundation
import os

/// S0 探针的落盘日志。容器 App 与 appex 共用同一份实现。
///
/// ## 为什么路径这么绕
///
/// **appex 必须沙盒化**（macOS 的硬性要求，否则 `pkd` 根本不会注册扩展 —— 详见
/// `docs/S0-PROBE.md`）。沙盒进程只能写自己的容器：
///
///     ~/Library/Containers/com.zhuyuhao.Mailingo.MailExtension/Data/Library/Logs/Mailingo/
///
/// 而容器 App 是**非沙盒**的（它以后要用 Accessibility 做"让 Mail 让出空间"，
/// 见 `docs/IMPLEMENTATION_PLAN.md` §5.2），所以它能直接读写上面那个路径。
///
/// 于是两个进程约定用同一个绝对路径 —— 这同时**预演了架构 C 里
/// appex → 容器 App 的数据交接机制**（真实版本会用 App Group，见 §2.5）。
public final class ProbeLog: @unchecked Sendable {

    public static let shared = ProbeLog()

    /// 共享路径集中在 `SharedPaths` 里（appex 沙盒容器 → 容器 App 可直读）。
    public static var directory: URL { SharedPaths.logs }

    /// 早先非沙盒版本留下的位置，读取时作为兜底。
    public static var legacyDirectory: URL { SharedPaths.legacyLogs }

    public static var logURL: URL { directory.appendingPathComponent("probe.log") }
    public static var lastMessageURL: URL { directory.appendingPathComponent("last-message.eml") }

    /// 行为开关：存在时 `decodedMessage` 返回 nil（只观察是否被调用）。
    public static var returnNilFlagURL: URL { directory.appendingPathComponent("return-nil") }

    private let lock = NSLock()
    private let osLogger = Logger(subsystem: "com.zhuyuhao.Mailingo", category: "probe")
    private let timestamp = ISO8601DateFormatter()

    private init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    /// 记录一条事件。同时写 os_log（`make stream` 可实时看）和落盘日志。
    ///
    /// ⚠️ 写入是**同步**的，这是刻意的：appex 是 Mail 拉起的短生命周期进程，
    /// 早先版本用 `queue.async` 异步落盘，结果目录建好了、日志却一行没有 ——
    /// 进程在异步块执行前就退出了。排障场景下"宁可阻塞也要写下去"。
    public func record(_ message: String) {
        osLogger.notice("\(message, privacy: .public)")
        let line = "[\(timestamp.string(from: Date()))] pid=\(ProcessInfo.processInfo.processIdentifier) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if !Self.append(line, to: Self.logURL) {
            // 落盘失败也要留下痕迹（只能靠 os_log 了）—— 多半是沙盒写权限问题。
            osLogger.fault("❌ 写日志失败：\(Self.logURL.path, privacy: .public)")
        }
    }

    /// 把拿到的原始邮件落盘，供离线核对完整性。
    public func dumpRawMessage(_ data: Data, label: String) {
        lock.lock()
        do {
            let url = Self.lastMessageURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
        lock.unlock()
        record("raw MIME dumped (\(label)): \(data.count) bytes → \(Self.lastMessageURL.path)")
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for url in [Self.logURL, Self.lastMessageURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func readLog() -> String {
        for url in [Self.logURL, Self.legacyDirectory.appendingPathComponent("probe.log")] {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return ""
    }

    @discardableResult
    private static func append(_ text: String, to url: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else { return false }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            // 显式 flush：appex 随时可能被 Mail 回收，不能等缓冲区自己刷。
            try handle.synchronize()
            return true
        } catch {
            return false
        }
    }
}
