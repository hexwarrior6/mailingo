import AppKit
import SwiftUI
import os

/// 让 Mailingo 跟着 Mail 一起显示 / 隐藏。
///
/// - Mail 被隐藏（右键 Dock 图标 → 隐藏，或 ⌘H）→ 我们也隐藏
/// - Mail 重新显示 → 我们也显示，并把窗口提到最前
///
/// ## 为什么**不**跟"Mail 被激活"
///
/// 一开始还挂了 `didActivateApplicationNotification`，想做到"Mail 一到前台我们
/// 也到前台"。但那会撞上一个死结：**"你单击 Mail"和"Mail 到前台"是同一个事件**。
///
/// 于是两窗口重叠、我们在上面时，你单击 Mail 想让它上来 —— 通知立刻触发，
/// 我们又把位置抢回去。你点第二次才正常，因为那时 Mail 已经是活动 App，
/// 不会再发激活通知。
///
/// "单击 Mail"并不等于"Mail 被打开"。用户说的「打开 / 隐藏」是一对，
/// 对应的是 **unhide / hide**，跟"激活"没有关系。所以只跟这两个。
///
/// ## 为什么用 `didHide` 而不是 `didDeactivate`
///
/// 这两件事在 macOS 里是**各自独立的通知**，语义完全不同：
///
/// | 信号 | 何时触发 |
/// |---|---|
/// | `didDeactivateApplication` | 切到**任何**别的 App 都会触发 —— 太宽 |
/// | `didHideApplication` | 用户**主动隐藏**这个 App —— 正是我们要的 |
///
/// 一开始用错了 `didDeactivate`，于是"切到浏览器查个资料"也会把译文窗口收走；
/// 而且它还带来一个竞态：App 被 `mailingo://` 拉起来时会激活自己，Mail 随之
/// 失活、通知立刻打过来，那时前台状态还没稳定，很容易误判。
///
/// 换成 `didHide` 之后信号是精确的，那个竞态自然消失了 ——
/// App 被拉起时 Mail 只是失活、并没有被隐藏，根本不会触发这条通知。
///
/// ## 提窗为什么不用 `NSApp.activate()`
///
/// 用 `activate()` 才叫"我们也到前台"，但它等于**把活动 App 从 Mail 抢过来**：
/// Mail 一被激活就立刻失去键盘焦点，你点进 Mail 打字却打到了我们这边。
/// 那不是跟随，是把 Mail 踢下去，结果是 Mail 根本没法用。
///
/// `orderFrontRegardless()` 只把窗口提到最前，**不改活动 App、不改键盘焦点**。
///
/// ## 信号来源不需要权限
///
/// `NSWorkspace` 的应用通知既不是 Apple Events，也不是 Accessibility，
/// 不需要任何授权。
final class MailActivationFollower {

    static let shared = MailActivationFollower()

    /// 「跟随 Mail 一起显示 / 隐藏」的开关。
    ///
    /// 始终挂着观察者、在回调里读这个标志 —— 通知频率极低（切 App 才有），
    /// 没必要为它维护启停状态。设置界面直接写同一个 key。
    static let enabledKey = "followMailActivation"

    private static let mailBundleID = "com.apple.mail"

    private let logger = Logger(subsystem: "com.zhuyuhao.Mailingo", category: "follow")
    private var observers: [NSObjectProtocol] = []

    /// 我们的主窗口。
    ///
    /// 不能用 `NSApp.windows.first` —— 那可能是设置窗口。所以由 `RootView`
    /// 里的 `WindowAccessor` 把真正的宿主窗口交进来。
    weak var mainWindow: NSWindow?

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private init() {}

    /// 挂上观察者。App 启动时调一次即可 —— 之后靠 `enabledKey` 控制是否生效。
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        // 显示：**只**跟"从隐藏状态恢复"，不跟"被激活"。理由见类注释。
        observers.append(center.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, Self.isMail(note) else { return }
            self.mailBecameVisible()
        })

        // 隐藏：**只有**用户主动隐藏 Mail 才会触发（见类注释里的对比表）
        observers.append(center.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, Self.isMail(note) else { return }
            self.mailWasHidden()
        })
    }

    // MARK: - 私有

    private static func isMail(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == mailBundleID
    }

    private func mailBecameVisible() {
        guard isEnabled, let window = mainWindow else { return }

        // 我们可能刚刚跟着 Mail 一起隐藏了，先放出来。
        // 注意是 `unhideWithoutActivation` —— 同样不能激活自己。
        NSApp.unhideWithoutActivation()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        logger.notice("跟随：Mail 显示 → 我们也显示并提到最前（不抢键盘焦点）")
    }

    private func mailWasHidden() {
        guard isEnabled else { return }
        NSApp.hide(nil)
        logger.notice("跟随：Mail 被隐藏 → 我们也隐藏")
    }
}

/// 把宿主 `NSWindow` 交给 `MailActivationFollower`。
///
/// SwiftUI 不直接暴露窗口对象，而 `orderFrontRegardless()` 必须要它。
/// 用最小的一个 `NSView` 从视图树里把 `view.window` 取出来。
struct WindowAccessor: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // `makeNSView` 返回时视图还没进窗口树，`window` 仍是 nil，
        // 所以推到下一个 runloop 再取一次。
        DispatchQueue.main.async { MailActivationFollower.shared.mainWindow = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        MailActivationFollower.shared.mainWindow = view.window
    }
}
