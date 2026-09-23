import AppKit
import os

/// 把主窗口贴到屏幕右半边。
///
/// ## 为什么不能一收到请求就 `setFrame`
///
/// SwiftUI 的 `Window` 场景**自己管窗口尺寸**（`.defaultSize` +
/// `.windowResizability`）。冷启动时的那次布局发生在窗口第一次显示的时候，
/// 晚于 `onOpenURL` 回调 —— 于是"收到请求就摆"会被随后的初次布局覆盖掉，
/// 表现出来就是**摆了个寂寞，窗口还是默认样式**。
///
/// 所以这里记一个**待办**，等窗口 `didBecomeKey`（SwiftUI 已经摆好了）再动手。
///
/// ## 为什么需要 `.canJoinAllApplications`
///
/// Mail 处在全屏时，我们的普通窗口会落在**桌面空间**，而 Mail 在它自己的
/// 全屏空间 —— 两个窗口根本不在同一个空间里，谈不上并排。
///
/// 官方说明（macOS 13+）：
///
/// > Marks a window as able to join all applications, allowing it to
/// > **join other apps' sets and full screen spaces** when eligible.
///
/// 这个行为要**尽早**设置：等到窗口已经显示出来再改，它不会搬到别的空间去。
/// 所以 `attach` 时就设，不等摆放请求。
///
/// ## 做不到的部分（别指望）
///
/// - **命令系统做真分屏**（Mail 跟着收窄重排）：AppKit 里没有任何"执行分屏"的
///   API，只有 `FullScreenAllowsTiling` 这类**权限标志** —— 能声明"我愿意被
///   分屏"，不能命令"现在分"。Apple 刻意让 Split View 必须由用户发起。
/// - **让 Mail 退出全屏**：`NSRunningApplication` 只能 activate / hide /
///   terminate；控制别的 App 的窗口要走 Accessibility 的 UI 脚本，是另一套权限。
///
/// 所以 Mail 全屏时它**仍然占满整个屏幕**，我们只是盖在它右半边上面。
enum WindowTiler {

    /// 「Mail 全屏时，把译文窗口贴到屏幕右半边」的开关。
    static let enabledKey = "tileWindowRightHalf"

    private static let logger = Logger(subsystem: "com.zhuyuhao.Mailingo", category: "window")

    /// 待摆放。用户点了「翻译」就置上，等窗口成为 key 时兑现。
    private static var pending = false
    private static weak var window: NSWindow?
    private static var observers: [NSObjectProtocol] = []

    private static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// `WindowAccessor` 拿到宿主窗口时调用。**尽早**把该设的行为设上。
    static func attach(_ newWindow: NSWindow) {
        guard window !== newWindow || observers.isEmpty else { return }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()

        window = newWindow

        // 全屏空间这件事必须"入伙在前"——等窗口显示出来再改 collectionBehavior，
        // 它不会搬进别的 App 的全屏空间。
        if isEnabled { grantFullScreenJoining(newWindow) }

        // 窗口成为 key 说明 SwiftUI 已经摆好了它，这时改 frame 才不会被覆盖。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: newWindow,
            queue: .main
        ) { _ in
            applyIfPending()
        })
    }

    /// 用户点了 Mail 里的「翻译」。
    static func requestRightHalf() {
        guard isEnabled else {
            logger.notice("窗口摆放：开关没开 → 跳过")
            return
        }

        pending = true
        logger.notice("窗口摆放：收到请求，等窗口成为 key 再摆")

        // 已经在显示中（比如窗口一直开着）就不用等通知了，直接摆。
        if let window, window.isVisible, window.isKeyWindow {
            applyIfPending()
        }
    }

    // MARK: - 私有

    private static func grantFullScreenJoining(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        behavior.insert(.canJoinAllApplications)
        window.collectionBehavior = behavior
        logger.notice("窗口摆放：已允许加入其它 App 的全屏空间")
    }

    private static func applyIfPending() {
        guard pending, let window else { return }
        pending = false

        guard let screen = window.screen ?? NSScreen.main else { return }

        // 再设一次，幂等；`attach` 时若开关还没开就靠这里补上。
        grantFullScreenJoining(window)

        // 用 visibleFrame 而不是 frame：避开菜单栏和 Dock；全屏空间里它会退化
        // 成整块屏幕，两种情况下都合适。
        let area = screen.visibleFrame
        let half = NSRect(
            x: area.midX,
            y: area.minY,
            width: area.width / 2,
            height: area.height
        )

        // 推一帧再设：躲开 SwiftUI 当前这轮布局。didBecomeKey 时它多半已经摆完，
        // 但首帧的收尾动作有可能还在队列里。
        DispatchQueue.main.async {
            window.setFrame(half, display: true, animate: false)
            logger.notice("""
                窗口摆放：已摆到右半边 \
                \(Int(half.width))×\(Int(half.height)) @ \(Int(half.minX)),\(Int(half.minY)) \
                collectionBehavior=\(window.collectionBehavior.rawValue)
                """)
        }
    }
}
