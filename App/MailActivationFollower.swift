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
/// ## "Mail 退到后台，我们也退"为什么是**单独一个**开关
///
/// 提窗是安全的：只抬层级，不改活动 App。而"退到后台"必须真的把窗口藏起来
/// （`NSApp.hide`），代价是实打实的：
///
/// 1. **macOS 全屏分屏（Split View）下会拆散分屏** —— 两个 App 本来是同一个
///    空间一起进退，单独把我们的窗口藏掉会让那一半变空。普通窗口并排则没这问题。
/// 2. 用户切到别的 App 查个资料，回来发现译文窗口不见了。跟随功能会把它放回来，
///    但那一下仍然是"东西不见了"。
///
/// 所以两个方向拆成两个开关，默认都关，由用户自己权衡。
///
/// ## 信号来源
///
/// `NSWorkspace` 的 `didActivateApplicationNotification`，按 bundle id 认出 Mail。
/// **不需要任何权限**：这不是 Apple Events，也不是 Accessibility。
final class MailActivationFollower {

    static let shared = MailActivationFollower()

    /// 「Mail 到前台 → 我们提窗」的开关。
    /// 始终挂着观察者、在回调里读这个标志 —— 通知频率极低（切 App 才有），
    /// 没必要为它维护启停状态。设置界面直接写同一个 key。
    static let enabledKey = "followMailActivation"

    /// 「Mail 退到后台 → 我们藏起来」的开关。单独一个，理由见类注释。
    static let hidesWhenMailHidesKey = "hideWhenMailGoesBack"

    private static let mailBundleID = "com.apple.mail"

    private let logger = Logger(subsystem: "com.zhuyuhao.Mailingo", category: "follow")
    private var observers: [NSObjectProtocol] = []

    /// 我们的主窗口。
    ///
    /// 不能用 `NSApp.windows.first` —— 那可能是设置窗口。所以由 `RootView`
    /// 里的 `WindowAccessor` 把真正的宿主窗口交进来。
    weak var mainWindow: NSWindow?

    private var raisesWhenMailAppears: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private var hidesWhenMailGoesBack: Bool {
        UserDefaults.standard.bool(forKey: Self.hidesWhenMailHidesKey)
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

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.mailBundleID else { return }
            self.mailWentBack()
        })
    }

    private func mailCameForward() {
        guard raisesWhenMailAppears, let window = mainWindow else { return }

        // 窗口可能因为 Mail 之前退到后台而被我们藏起来了，先放出来再提到最前。
        // 注意是 `unhideWithoutActivation` —— 同样不能激活自己。
        NSApp.unhideWithoutActivation()
        window.orderFrontRegardless()
        logger.notice("""
            跟随：Mail 到前台 → 提窗 \
            前置App=\(Self.frontmostID) 本App是否活动=\(NSApp.isActive)
            """)
    }

    /// Mail 退到后台。
    ///
    /// 只在**单独**开了"也藏起来"时才动。默认什么都不做 —— 我们本来就没占
    /// 前台那个位置，"我们在后台"一直成立，不需要代码去实现。
    private func mailWentBack() {
        guard hidesWhenMailGoesBack else { return }

        // ★ 这道判断不能少：Mail 失活**可能是我们自己造成的** —— 用户点了我们的
        //   窗口，于是我们变成活动 App、Mail 失活。这时如果照做把自己藏起来，
        //   用户正在操作的窗口会当场消失。
        let frontmost = Self.frontmostID
        guard frontmost != Bundle.main.bundleIdentifier else {
            logger.notice("跟随：Mail 失活但前台是我们自己（用户点了我们的窗口）→ 不藏")
            return
        }

        NSApp.hide(nil)
        logger.notice("""
            跟随：Mail 退到后台 → 藏起窗口 \
            前置App=\(frontmost) 本App是否活动=\(NSApp.isActive)
            """)
    }

    /// 当前前台 App 的 bundle id，只用于日志。
    private static var frontmostID: String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<无>"
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
