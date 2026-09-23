import EmailCore
import Foundation

/// Mail 当前选中的那封邮件。
public struct MailSelection: Sendable, Equatable {
    /// Internet Message-ID，已去掉尖括号并 trim。
    ///
    /// 用它是为了和我们已捕获的邮件对上号 —— `MessageStore` 里存的就是这个头。
    public let internetMessageID: String
    /// Mail 内部的数字 id（跨重启不稳定，只用于日志）。
    public let mailMessageID: Int?

    public init(internetMessageID: String, mailMessageID: Int?) {
        self.internetMessageID = internetMessageID
        self.mailMessageID = mailMessageID
    }
}

public enum MailSelectionError: Error, CustomStringConvertible, Equatable {
    /// Mail 没在运行
    case mailNotRunning
    /// 没有打开阅读窗口
    case noViewer
    /// 阅读窗口里没有选中任何邮件
    case noSelection
    /// 用户拒绝了「自动化」权限
    case automationDenied
    case scriptFailed(code: Int, message: String)

    public var description: String {
        switch self {
        case .mailNotRunning: "Mail 没有运行"
        case .noViewer: "Mail 没有打开阅读窗口"
        case .noSelection: "阅读窗口里没有选中邮件"
        case .automationDenied:
            "没有获得「自动化」权限，无法查询 Mail 当前选中的邮件"
        case .scriptFailed(let code, let message):
            "查询 Mail 失败（\(code)）：\(message)"
        }
    }

    /// 这两种不是错误，是"现在没得可跟"，调用方应当安静跳过。
    public var isTransient: Bool {
        switch self {
        case .noViewer, .noSelection, .mailNotRunning: true
        case .automationDenied, .scriptFailed: false
        }
    }
}

/// 查询 Mail 当前选中的是哪一封邮件。
///
/// ## 为什么需要它（以及为什么当初删掉又复活）
///
/// 邮件**内容**是 Mail 主动推给扩展的（`decodedMessage`），不需要主动去要 ——
/// 所以最初把"用 AppleScript 去问 Mail"整节删掉了。
///
/// 但**"用户此刻在看哪一封"是另一回事，Mail 不推这个信息**。
/// 被动信号（解码回调）很不可靠：实测 59 个相邻间隔里 38 个小于 1.5 秒，
/// 那些是滚动列表/预取/打开会话时的**批量解码**，跟"用户打开了哪一封"无关。
///
/// 所以这一项要主动查询。代价是一次「自动化」授权。
///
/// ## 工程注意
///
/// - `NSAppleScript` **阻塞且非线程安全**，一律在专用串行队列上跑，绝不占用主线程。
/// - Apple Event 在 Mail 弹模态对话框时可能挂住，所以脚本里写了 `with timeout`，
///   外层再用 `Task` 兜一层超时。
public final class MailSelectionMonitor: @unchecked Sendable {

    public static let shared = MailSelectionMonitor()

    /// 专用串行队列：`NSAppleScript` 不能并发用，也绝不能阻塞主线程。
    private let queue = DispatchQueue(label: "com.zhuyuhao.Mailingo.mail-selection")
    /// 编译一次后复用（编译很慢，执行很快）。只在 `queue` 上访问。
    private var compiledScript: NSAppleScript?

    private init() {}

    /// 查询当前选中的邮件。耗时操作为阻塞式，内部已挪到后台队列。
    public func currentSelection() async throws -> MailSelection {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.runQuery())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 私有

    private func runQuery() throws -> MailSelection {
        let script = try script()
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            throw Self.mapError(errorInfo)
        }

        let raw = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return try Self.parse(raw)
    }

    private func script() throws -> NSAppleScript {
        if let compiledScript { return compiledScript }

        // 用 ASCII 0x1F 作分隔符：Message-ID 里不会出现它，Subject 里也几乎不会。
        let source = """
        with timeout of 10 seconds
            tell application "Mail"
                if (count of message viewers) is 0 then return "NOVIEWER"
                set theSelection to selected messages of item 1 of message viewers
                if (count of theSelection) is 0 then return "NOSELECTION"
                set m to item 1 of theSelection
                set theMessageID to ""
                try
                    set theMessageID to (message id of m) as text
                end try
                set theNumericID to ""
                try
                    set theNumericID to (id of m) as text
                end try
                return "OK" & (ASCII character 31) & theMessageID & (ASCII character 31) & theNumericID
            end tell
        end timeout
        """

        guard let script = NSAppleScript(source: source) else {
            throw MailSelectionError.scriptFailed(code: 0, message: "脚本无法创建")
        }

        var errorInfo: NSDictionary?
        script.compileAndReturnError(&errorInfo)
        if let errorInfo {
            throw Self.mapError(errorInfo)
        }

        compiledScript = script
        return script
    }

    private static func mapError(_ info: NSDictionary) -> MailSelectionError {
        let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "未知错误"

        switch code {
        case -1743, -1744:      // errAEEventNotPermitted / errAEEventWouldRequireUserConsent
            return .automationDenied
        case -600, -609:        // procNotFound / connectionInvalid
            return .mailNotRunning
        default:
            return .scriptFailed(code: code, message: message)
        }
    }

    /// 解析脚本返回的 `OK\u{1F}<message-id>\u{1F}<数字 id>`。
    static func parse(_ raw: String) throws -> MailSelection {
        switch raw {
        case "NOVIEWER", "": throw MailSelectionError.noViewer
        case "NOSELECTION": throw MailSelectionError.noSelection
        default: break
        }

        let separator = Character(UnicodeScalar(31))
        let parts = raw.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "OK" else {
            throw MailSelectionError.scriptFailed(code: 0, message: "返回值无法解析：\(raw.prefix(60))")
        }

        let messageID = MIMEHeaders.normalizeMessageID(parts[1])
        guard !messageID.isEmpty else {
            // Mail 对某些邮件给不出 Message-ID（草稿、部分本地邮件）。
            // 没有它就没法和已捕获的邮件对上号，只能当作"没选中"。
            throw MailSelectionError.noSelection
        }

        return MailSelection(
            internetMessageID: messageID,
            mailMessageID: parts.count > 2 ? Int(parts[2]) : nil
        )
    }

}
