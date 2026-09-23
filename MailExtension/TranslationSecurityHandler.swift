import AppKit
import MailKit

/// # Mail 扩展：翻译入口 + 邮件数据源
///
/// 这个类只做三件事：
///
/// 1. **把 Mail 递来的每一封邮件按 ID 存好**（`MessageStore`），互不覆盖；
/// 2. 在阅读窗格挂一条横幅 / 头部图标；
/// 3. 用户点击时，把「点的是哪一封」精确传出去，并唤醒容器 App 显示侧栏。
///
/// ## 为什么第 1、3 步必须做对
///
/// Mail 会把**会话（来回好几封）里的每一封都解码一遍** —— 实测 200 次调用出现
/// 了十几个不同大小。早先所有邮件都写进同一个 `last-message.eml`，
/// 于是容器 App 拿到的是"最后被解码的那封"，跟用户正在看哪一封毫无关系；
/// 表现就是「只能识别到第一封」「双击单独打开那封才识别得到」。
///
/// 现在 banner 的 `context` 里带着邮件 ID：Mail 会在用户点击时把它原样回传，
/// 我们因此能确定「用户点的是线程里的哪一封」。
final class TranslationSecurityHandler: NSObject, MEMessageSecurityHandler {

    // MARK: - 开关

    /// 是否对每封邮件都返回非 nil 的 `MEDecodedMessage`。
    ///
    /// 用文件开关而不是重新编译：改开关不需要重装扩展、不需要重启 Mail。
    /// 删除该文件即恢复 `true`。
    private var shouldClaimDecode: Bool {
        !FileManager.default.fileExists(
            atPath: SharedPaths.logs.appendingPathComponent("return-nil").path
        )
    }

    // MARK: - MEMessageEncoder（本扩展不做加密，协议要求实现）

    func getEncodingStatus(
        for message: MEMessage,
        composeContext: MEComposeContext,
        completionHandler: @escaping (MEOutgoingMessageEncodingStatus) -> Void
    ) {
        completionHandler(
            MEOutgoingMessageEncodingStatus(
                canSign: false,
                canEncrypt: false,
                securityError: nil,
                addressesFailingEncryption: []
            )
        )
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

    // MARK: - MEMessageDecoder ★ 数据源在这里

    func decodedMessage(forMessageData data: Data) -> MEDecodedMessage? {
        // ① 先存下来。**每封一个文件**，不再互相覆盖。
        let stored = MessageStore.save(rawMIME: data)

        ProbeLog.shared.record(
            """
            ────────────────────────────────────────────────
            ★ decodedMessage 被调用
              id         = \(stored.id)
              bytes      = \(stored.byteCount)
              subject    = \(stored.subject.isEmpty ? "<无>" : stored.subject)
              from       = \(stored.from.isEmpty ? "<无>" : stored.from)
              date       = \(stored.date.map(String.init(describing:)) ?? "<无>")
              已捕获邮件 = \(MessageStore.all().count) 封
              判定       = \(shouldClaimDecode ? "返回非 nil（显示横幅）" : "返回 nil（基线）")
            """
        )
        ProbeLog.shared.dumpRawMessage(data, label: "decodedMessage")

        guard shouldClaimDecode else { return nil }

        let securityInfo = MEMessageSecurityInformation(
            signers: [],
            isEncrypted: false,
            signingError: nil,
            encryptionError: nil
        )

        // dismissable: false —— 不要给用户一个"点一下就消失"的横幅。
        // 保留着才能反复点击（重新翻译、或第一次失败后重试）。
        let banner = MEDecodedMessageBanner(
            title: "翻译这封邮件",
            primaryActionTitle: "翻译",
            dismissable: false
        )

        // ② context 带上 ID —— Mail 会在用户点击时原样回传，
        //    这就是"用户点的是线程里哪一封"的唯一可靠来源。
        return MEDecodedMessage(
            data: data,
            securityInformation: securityInfo,
            context: Self.contextData(messageID: stored.id),
            banner: banner
        )
    }

    // MARK: - 呈现 UI：**一律不开窗口**

    // 三条回调全部返回 nil，这是刻意的。
    //
    // 产品形态是「Mail 左边照常显示原文，译文出现在 Mailingo 自己的窗口里」，
    // 所以 Mail 这边只需要把请求交出去，**不该再弹任何东西**。
    //
    // 早先这里返回了一个 `MEExtensionViewController`，Mail 会把它当成一个新窗口
    // 弹出来 —— 那正是"点一下翻译就多出一个窗口"的来源；而这次交互同时把横幅
    // 消费掉了，于是横幅也跟着消失。两个症状同一个根因。

    /// 用户点击**邮件头部视图里的扩展图标**时调用。
    func extensionViewController(signers messageSigners: [MEMessageSigner]) -> MEExtensionViewController? {
        ProbeLog.shared.record("★ extensionViewController(signers:) 被调用（不开窗口）")
        // 这条路径拿不到 context，只能退化成"最近捕获的那封"
        if let message = MessageStore.mostRecent() {
            requestTranslation(of: message, reason: "头部图标")
        }
        return nil
    }

    /// 用户点击**横幅**时调用，带 Mail 回传的 context —— 能确定是哪一封。
    func extensionViewController(messageContext context: Data) -> MEExtensionViewController? {
        if let message = resolve(context: context, reason: "extensionViewController(messageContext:)") {
            requestTranslation(of: message, reason: "横幅")
        }
        return nil
    }

    /// 横幅上**主操作按钮**被点击时调用。
    func primaryActionClicked(
        forMessageContext context: Data,
        completionHandler: @escaping (MEExtensionViewController?) -> Void
    ) {
        if let message = resolve(context: context, reason: "primaryActionClicked") {
            requestTranslation(of: message, reason: "横幅主操作")
        }
        // 传 nil：不呈现任何 UI，Mail 也就没有"新窗口"可开
        completionHandler(nil)
    }

    /// 把「翻译这一封」的请求交出去。
    ///
    /// 去重：同一次点击可能同时命中两条回调，没必要重复写请求、重复唤醒 App。
    private func requestTranslation(of message: StoredMessage, reason: String) {
        let now = Date()
        if let last = lastRequest, last.id == message.id, now.timeIntervalSince(last.at) < 1.0 {
            ProbeLog.shared.record("（\(reason)）与上一次请求重复，跳过")
            return
        }
        lastRequest = (id: message.id, at: now)

        MessageStore.writePendingRequest(messageID: message.id)
        openContainerApp(messageID: message.id)
    }

    /// 上一次发出的请求，用于去重。
    private var lastRequest: (id: String, at: Date)?

    // MARK: - 私有

    private func resolve(context: Data, reason: String) -> StoredMessage? {
        guard let id = Self.messageID(fromContext: context) else {
            ProbeLog.shared.record("★ \(reason) context 里没有 id，退化为最近一封")
            return MessageStore.mostRecent()
        }
        guard let message = MessageStore.all().first(where: { $0.id == id }) else {
            ProbeLog.shared.record("★ \(reason) id=\(id) 但仓库里找不到对应邮件")
            return nil
        }
        ProbeLog.shared.record("★ \(reason) 命中 id=\(id)｜\(message.displayTitle)")
        return message
    }

    /// 用自定义 URL scheme 唤醒容器 App。
    ///
    /// appex 是沙盒进程，不能随意拉起别的 App；但通过 LaunchServices 打开一个
    /// 已注册的 URL scheme 是允许的。容器 App 的 `onOpenURL` 会收到它。
    private func openContainerApp(messageID: String) {
        guard let url = URL(string: "mailingo://translate?id=\(messageID)") else { return }
        let opened = NSWorkspace.shared.open(url)
        ProbeLog.shared.record("   唤醒容器 App：\(opened ? "成功" : "失败") → \(url.absoluteString)")
    }

    private static func contextData(messageID: String) -> Data {
        (try? JSONEncoder().encode(["id": messageID])) ?? Data(messageID.utf8)
    }

    private static func messageID(fromContext context: Data) -> String? {
        // 新格式是 JSON；老格式是纯字符串，两者都认。
        if let object = try? JSONSerialization.jsonObject(with: context) as? [String: String],
           let id = object["id"] {
            return id
        }
        let raw = String(data: context, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "{} \n\t\""))
        return (raw?.isEmpty == false) ? raw : nil
    }
}
