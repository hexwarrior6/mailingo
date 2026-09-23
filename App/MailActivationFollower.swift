import AppKit
import SwiftUI
import os

/// Mail 到前台时，把我们的窗口也提到最前。
///
/// ## 为什么不抢活动状态（这个功能的全部难点）
///
/// 直觉做法是 `NSApp.activate()` —— 那才叫"我们也到前台"。但它等于**把活动
/// App 从 Mail 抢过来**：Mail 一被激活就立刻失去键盘焦点，你点进 Mail 打字
/// 却打到了我们这边。那不是跟随，是把 Mail 踢下去，结果是 Mail 根本没法用。
///
/// `orderFrontRegardless()` 只把窗口提到最前，**不改活动 App、不改键盘焦点**。
/// Mail 照常能用，我们的窗口也照样出现在前排。
///
/// 代价：菜单栏仍然属于 Mail。这是刻意的 —— 想要菜单栏切到 Mailingo，
/// 就必须真的激活自己，而那样 Mail 就没法用了。
///
/// ## 为什么没有"Mail 退到后台，我们也退"
///
/// 因为**我们从来就没占过前台那个位置** —— 不抢活动状态，"我们在后台"
/// 就是一直成立的事实，不需要任何代码去实现。
///
/// 而如果真去 `NSApp.hide()` 把窗口藏起来，会有两个坏处：
///
/// 1. **分屏（Split View）下会留一个空洞。** 两个窗口并排时"Mail 退到后台"
///    是**整个空间一起退**，本来就同步；单独把我们的窗口藏掉反而会拆散分屏。
/// 2. 用户切到别的 App 查个资料，回来发现译文窗口不见了 —— 那是丢状态，不是跟随。
///
/// ## 信号来源
///
/// `NSWorkspace` 的 `didActivateApplicationNotification`，按 bundle id 认出 Mail。
/// **不需要任何权限**：这不是 Apple Events，也不是 Accessibility。
final class MailActivationFollower {

    static let shared = MailActivationFollower()

    /// 开关。始终挂着观察者、在回调里读这个标志 —— 通知频率极低（切 App 才有），
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
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.mailBundleID else { return }
            self.mailCameForward()
        })
    }

    private func mailCameForward() {
        guard isEnabled, let window = mainWindow else { return }

        // 窗口可能因为 Mail 之前退到后台而被系统隐没，先放出来再提到最前。
        // 注意是 `unhideWithoutActivation` —— 同样不能激活自己。
        NSApp.unhideWithoutActivation()
        window.orderFrontRegardless()
        logger.notice("Mail 到前台 → 把窗口提到最前（不抢键盘焦点）")
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
