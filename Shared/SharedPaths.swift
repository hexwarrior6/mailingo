import Foundation

/// appex 与容器 App 之间的共享路径。
///
/// appex 必须沙盒化（见 docs/S0-PROBE.md），所以它的数据落在自己的容器里：
///
///     ~/Library/Containers/com.zhuyuhao.Mailingo.MailExtension/Data/Library/...
///
/// 容器 App 是**非沙盒**的，能直接读写这个绝对路径 —— 这就是两个进程的交接通道。
/// 将来要做多点同步/上架时换 App Group，路径解析集中在这里，改一处即可。
public enum SharedPaths {

    public static let extensionBundleID = "com.zhuyuhao.Mailingo.MailExtension"

    /// 真实 home。
    ///
    /// 沙盒进程的 `homeDirectoryForCurrentUser` 会返回容器路径，所以这里走 passwd
    /// 直接拿 `/Users/xxx` —— 保证 appex 与容器 App 算出同一个结果。
    public static var realHome: URL {
        if let pw = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// appex 沙盒容器的 Data 目录。
    public static var containerData: URL {
        realHome
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(extensionBundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 日志（S0 探针与翻译自检）

    public static var logs: URL {
        containerData.appendingPathComponent("Library/Logs/Mailingo", isDirectory: true)
    }

    /// 早先非沙盒版本写过的位置，读取时兜底。
    public static var legacyLogs: URL {
        realHome.appendingPathComponent("Library/Logs/Mailingo", isDirectory: true)
    }

    // MARK: - 捕获到的邮件

    /// 邮件仓库。**每封邮件存一个文件，不再互相覆盖。**
    public static var messages: URL {
        ensure(appSupport.appendingPathComponent("messages", isDirectory: true))
    }

    /// 「用户点了某封邮件的翻译按钮」这个请求。
    public static var pendingRequest: URL {
        appSupport.appendingPathComponent("pending-request.json")
    }

    private static var appSupport: URL {
        ensure(containerData.appendingPathComponent("Library/Application Support/Mailingo", isDirectory: true))
    }
}
