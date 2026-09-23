import AppKit
import SwiftUI
import os

/// 让 Mailingo 跟着 Mail 一起显示 / 隐藏。
///
/// - Mail 被隐藏（右键 Dock 图标 → 隐藏，或 ⌘H）→ 我们也隐藏
/// - Mail 重新显示 → 我们也显示，并把窗口提到最前
///
/// ## "Mail 被激活"要分两种情况
///
/// **"你单击 Mail"和"Mail 到前台"是同一个事件**，所以只看激活是分不开的：
///
/// | 当时的状态 | 用户的意思 | 该怎么做 |
/// |---|---|---|
/// | 我们压在 Mail 上面，上面没别的东西 | 想用 Mail | 别抢，让它上来 |
/// | 我们被浏览器之类压在下面 | 想两个一起看 | 提上来 |
///
/// 上一版只做了"提上来"，于是两窗口重叠时你单击 Mail 反而被我们盖回去；
/// 后来干脆不跟激活，结果"两个都被压在别的 App 后面时点 Mail"又提不起来了。
///
/// 现在用 `isCoveredByOtherApp` 区分：看我们上面有没有压着**别的 App**。
/// 关键是**把 Mail 排除在外** —— Mail 一被激活，它的窗口必然排到我们前面，
/// 算进去的话两种情况就永远分不开。
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

    /// Mail 是怎么"到前台"的。两者的处理不一样，见 `mailCameForward`。
    private enum VisibilityReason {
        /// 被激活 —— 可能是用户特意去点它
        case activated
        /// 从隐藏状态恢复 —— 我们自己跟着藏起来之后又一起回来
        case unhidden
    }

    private static let logger = Logger(subsystem: "com.zhuyuhao.Mailingo", category: "follow")
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

        // 显示：两种情况要分开对待，理由见 `mailCameForward`
        for (name, reason) in [
            (NSWorkspace.didActivateApplicationNotification, VisibilityReason.activated),
            (NSWorkspace.didUnhideApplicationNotification, VisibilityReason.unhidden),
        ] {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self, Self.isMail(note) else { return }
                self.mailCameForward(reason: reason)
            })
        }

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

    /// Mail 到前台了 —— 判断要不要把我们的窗口也提上来。
    ///
    /// ## 两种情况必须分开，否则一定会得罪一边
    ///
    /// | 当时的状态 | 用户的意思 | 该怎么做 |
    /// |---|---|---|
    /// | 我们压在 Mail 上面，上面没别的东西 | 想用 Mail | **别抢**，让它上来 |
    /// | 我们被浏览器之类压在下面 | 想两个一起看 | 提上来 |
    ///
    /// 只看"Mail 被激活"是分不开这两者的 —— 而"你单击 Mail"和"Mail 到前台"
    /// 本来就是同一个事件。上一版因此出现了"点一下 Mail 反而被我们盖回去"。
    ///
    /// 区分靠 `isCoveredByOtherApp`：看我们上面有没有压着**别的 App**。
    private func mailCameForward(reason: VisibilityReason) {
        guard isEnabled, let window = mainWindow else { return }

        // 「被激活」有可能是用户特意去点 Mail，这时不该抢；「从隐藏恢复」则是
        // 我们自己跟着 Mail 一起藏起来之后又一起回来，必须放出来。
        if reason == .activated, !Self.isCoveredByOtherApp(window) {
            Self.logger.notice("跟随：Mail 被激活，但我们上面没压着别的 App（只是想用 Mail）→ 不提窗")
            return
        }

        // 我们可能刚刚跟着 Mail 一起隐藏了，先放出来。
        // 注意是 `unhideWithoutActivation` —— 同样不能激活自己。
        NSApp.unhideWithoutActivation()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        Self.logger.notice("跟随：Mail \(reason == .unhidden ? "重新显示" : "被激活且我们被压住") → 提到最前")
    }

    /// 我们的窗口上面是否压着**别的 App**（Mail 除外）的窗口。
    ///
    /// 只看 `CGWindowList` 的**前后顺序**，不需要几何计算 —— 它按从前到后返回。
    ///
    /// 为什么必须把 **Mail 排除**：Mail 一被激活，它的窗口必然排到我们前面。
    /// 把它也算成遮挡的话，两种情况就再也分不开了 —— 那正是上一版
    /// "点了 Mail 我们却盖回去"的成因。
    private static func isCoveredByOtherApp(_ window: NSWindow) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let ourPID = Int(ProcessInfo.processInfo.processIdentifier)
        let ourNumber = window.windowNumber
        let mailPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: mailBundleID).first
            .map { Int($0.processIdentifier) }

        var above: [(pid: Int, layer: Int)] = []

        for entry in list {
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int else { continue }

            // ★ 只看**普通窗口层**。
            //
            // 这是踩过的坑：`CGWindowList` 把 Dock、菜单栏这些系统 UI 排在**最
            // 前面**（它们的 window level 更高），从前往后遍历第一个就撞上它们。
            // 那些窗口的 PID 既不是我们也不是 Mail，于是被当成"有别的 App 压着"
            // —— 结果就是"单击 Mail 我们反而盖回去"，也就是最早那个 bug。
            //
            // 我们的窗口是普通窗口（level 0），所以只跟同一层的比。
            guard layer == 0 else { continue }

            if number == ourNumber { break }   // 走到自己为止，上面的都看完了
            if pid == ourPID { continue }      // 自己的窗口不算
            above.append((pid, layer))
        }

        let others = above.filter { $0.pid != mailPID }
        if !others.isEmpty {
            Self.logger.notice("跟随：我们上面压着 \(others.count) 个别的 App 窗口（pid \(others.map(\.pid))）")
            return true
        }

        // 列表里没找到自己（比如在别的空间）→ 当作被挡住，该提窗。
        // 判断依据：上面 `break` 没发生过就没有记录到"走到自己"。
        return !list.contains { ($0[kCGWindowNumber as String] as? Int) == ourNumber }
    }

    private func mailWasHidden() {
        guard isEnabled else { return }
        NSApp.hide(nil)
        Self.logger.notice("跟随：Mail 被隐藏 → 我们也隐藏")
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
