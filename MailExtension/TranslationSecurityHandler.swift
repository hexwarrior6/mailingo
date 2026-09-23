import AppKit
import MailKit

/// # S0 探针：验证 Mail 扩展能否成为"翻译"的入口与数据源
///
/// 这个类只回答 4 个问题，全部写进 `~/Library/Logs/Mailingo/probe.log`：
///
/// 1. `decodedMessage(forMessageData:)` 对**普通未加密未签名邮件**到底会不会被调用？
/// 2. 如果返回非 nil 的 `MEDecodedMessage` + `banner`，Mail 会不会真的渲染横幅？
/// 3. 点横幅/头部图标后，Mail 会不会呈现我们自己的 `MEExtensionViewController`？
/// 4. `data` 参数是不是**完整的原始 MIME**？
///
/// ⚠️ 这个方法命中"借用 S/MIME 扩展点"的语义灰区：对一封普通的未加密未签名邮件
/// 返回非 nil，等于向 Mail 宣称"我解码了它"。S0 就是要看 Mail 会对这种宣称
/// 做出什么反应（是否显示错误的安全状态 UI）。
final class TranslationSecurityHandler: NSObject, MEMessageSecurityHandler {

    // MARK: - 开关

    /// 是否对每封邮件都返回非 nil 的 `MEDecodedMessage`。
    ///
    /// 用文件开关而不是重新编译：改开关不需要重装扩展、不需要重启 Mail。
    /// 删除该文件即恢复 `true`。
    ///   `touch   ~/Library/Logs/Mailingo/return-nil`  → 只观察会不会被调用（基线）
    ///   `rm      ~/Library/Logs/Mailingo/return-nil`  → 观察横幅是否渲染
    private var shouldClaimDecode: Bool {
        !FileManager.default.fileExists(
            atPath: ProbeLog.directory.appendingPathComponent("return-nil").path
        )
    }

    /// 传给 `MEDecodedMessage` 的 context，Mail 会原样回传给我们的 view controller。
    private static let probeContext = Data("mailingo-s0-probe".utf8)

    // MARK: - MEMessageEncoder（探针不需要，但协议要求实现）

    func getEncodingStatus(
        for message: MEMessage,
        composeContext: MEComposeContext,
        completionHandler: @escaping (MEOutgoingMessageEncodingStatus) -> Void
    ) {
        let status = MEOutgoingMessageEncodingStatus(
            canSign: false,
            canEncrypt: false,
            securityError: nil,
            addressesFailingEncryption: []
        )
        completionHandler(status)
    }

    func encode(
        _ message: MEMessage,
        composeContext: MEComposeContext,
        completionHandler: @escaping (MEMessageEncodingResult) -> Void
    ) {
        completionHandler(
            MEMessageEncodingResult(encodedMessage: nil, signingError: nil, encryptionError: nil)
        )
    }

    // MARK: - MEMessageDecoder ★ 这是 S0 的核心

    func decodedMessage(forMessageData data: Data) -> MEDecodedMessage? {
        let headers = Self.summarizeHeaders(data)
        ProbeLog.shared.record(
            """
            ────────────────────────────────────────────────
            ★ decodedMessage(forMessageData:) 被调用
              bytes      = \(data.count)
              subject    = \(headers.subject ?? "<无法解析>")
              from       = \(headers.from ?? "<无法解析>")
              content-type = \(headers.contentType ?? "<缺失>")
              判定       = \(shouldClaimDecode ? "返回非 nil（观察横幅）" : "返回 nil（基线，只观察是否被调用）")
            """
        )
        ProbeLog.shared.dumpRawMessage(data, label: "decodedMessage")

        guard shouldClaimDecode else { return nil }

        // 关键：不声明任何签名/加密信息，避免污染 Mail 的安全状态显示。
        let securityInfo = MEMessageSecurityInformation(
            signers: [],
            isEncrypted: false,
            signingError: nil,
            encryptionError: nil
        )

        let banner = MEDecodedMessageBanner(
            title: "Mailingo 探针：翻译这封邮件",
            primaryActionTitle: "翻译",
            dismissable: true
        )

        ProbeLog.shared.record("   → 返回非 nil MEDecodedMessage（带 banner）")

        return MEDecodedMessage(
            data: data,
            securityInformation: securityInfo,
            context: Self.probeContext,
            banner: banner
        )
    }

    // MARK: - 呈现我们的 UI

    /// 用户点击**邮件头部视图里的扩展图标**时调用。
    func extensionViewController(signers messageSigners: [MEMessageSigner]) -> MEExtensionViewController? {
        ProbeLog.shared.record(
            "★ extensionViewController(signers:) 被调用 (count=\(messageSigners.count)) → 呈现探针 VC"
        )
        return ProbeViewController(reason: .headerIcon, context: Self.probeContext)
    }

    /// 用户点击**横幅 / 头部图标**时调用（带 Mail 回传的 context）。
    func extensionViewController(messageContext context: Data) -> MEExtensionViewController? {
        let text = String(data: context, encoding: .utf8) ?? "<非 UTF-8>"
        ProbeLog.shared.record(
            "★ extensionViewController(messageContext:) 被调用 context=\"\(text)\" → 呈现探针 VC"
        )
        return ProbeViewController(reason: .messageContext, context: context)
    }

    /// 横幅上的**主操作按钮**被点击时调用。
    func primaryActionClicked(
        forMessageContext context: Data,
        completionHandler: @escaping (MEExtensionViewController?) -> Void
    ) {
        let text = String(data: context, encoding: .utf8) ?? "<非 UTF-8>"
        ProbeLog.shared.record(
            "★ primaryActionClicked(forMessageContext:) 被调用 context=\"\(text)\" → 呈现探针 VC"
        )
        completionHandler(ProbeViewController(reason: .bannerAction, context: context))
    }

    // MARK: - 极简头部解析（只为日志可读，不是产品代码）

    private struct HeaderSummary {
        var subject: String?
        var from: String?
        var contentType: String?
    }

    private static func summarizeHeaders(_ data: Data) -> HeaderSummary {
        // 头部是 ASCII/UTF-8 的超集。注意 Exchange/Office365 的头部区可以很长
        // （实测一封 Notice 的头部就有 152 行），所以窗口给足，别抠 8KB。
        let head = data.prefix(65536)
        guard let text = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .isoLatin1) else {
            return HeaderSummary()
        }

        var summary = HeaderSummary()
        // ⚠️ 必须用 `split(whereSeparator: \.isNewline)`。这个坑很 Swift 特有：
        //
        //   1. `components(separatedBy: .newlines)` 会把 CRLF 拆成两个分隔符，
        //      中间多出空串，`if line.isEmpty { break }` 于是在第一行后就退出。
        //   2. `split(separator: "\n")` 更糟 —— **在 Swift 里 "\r\n" 是单个 Character**
        //      （一个 grapheme cluster），所以它完全不在 CRLF 处切分，整封邮件变成一行。
        //
        //   `Character.isNewline` 对 CRLF 这个 grapheme 为 true，两种行尾都能正确切分。
        //   RFC 5322 规定行尾就是 CRLF，而 Mail 给我们的可能是 LF，两种都得支持。
        //
        // 上面这个坑、以及头部名大小写不敏感的问题，都是拿一封真实 .eml 跑一遍就立刻
        // 暴露的 —— 正是 IMPLEMENTATION_PLAN.md §6 fixture 黄金测试要拦的东西。
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { break }  // 头部结束

            // ⚠️ 两边都要小写。早先写成 `line.lowercased().hasPrefix(key + ":")` ——
            // 左边转小写、右边却保留 "Subject:" 的原始大小写，于是**永远不匹配**，
            // 日志里三个字段全是「无法解析」。RFC 5322 的头部名本就大小写不敏感。
            func value(_ key: String) -> String? {
                let prefix = key.lowercased() + ":"
                guard line.lowercased().hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }

            if let v = value("Subject") { summary.subject = v }
            else if let v = value("From") { summary.from = v }
            else if let v = value("Content-Type") { summary.contentType = v }
        }
        return summary
    }
}
