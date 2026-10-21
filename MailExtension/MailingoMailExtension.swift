import AppKit
import MailKit

/// Mail 扩展的主入口（`NSExtensionPrincipalClass`）。
///
/// Mail 只会向实现了 `MEExtensionCapabilities` 里声明过的 handler 索要实例。
/// S0 探针只声明了 `MEMessageSecurityHandler`，所以只需实现这一个工厂方法。
@objc(MailingoMailExtension)
public final class MailingoMailExtension: NSObject, MEExtension {

    private let securityHandler = TranslationSecurityHandler()

    public override init() {
        super.init()
        ProbeLog.shared.record("★ MailingoMailExtension 已实例化（Mail 加载了扩展）")
    }

    public func handlerForMessageSecurity() -> MEMessageSecurityHandler {
        ProbeLog.shared.record("MailingoMailExtension.handlerForMessageSecurity() 被调用")
        return securityHandler
    }
}
