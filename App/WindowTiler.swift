import AppKit
import os

/// 把主窗口贴到屏幕右半边。
///
/// ## 为什么需要 `.canJoinAllApplications`
///
/// 用户点 Mail 里的「翻译」时，Mail 可能正处在**全屏**状态。这时我们的窗口
/// 如果是个普通窗口，会落在**桌面空间**、而 Mail 在它自己的全屏空间 ——
/// 两个窗口根本不在同一个空间里，谈不上并排。
///
/// `NSWindowCollectionBehaviorCanJoinAllApplications`（macOS 13+）就是为这件事
/// 准备的。官方说明：
///
/// > Marks a window as able to join all applications, allowing it to
/// > **join other apps' sets and full screen spaces** when eligible.
///
/// ## 做不到的部分（别指望）
///
/// - **命令系统做真分屏**（Mail 跟着收窄重排）：AppKit 里没有任何"执行分屏"的
///   API，只有 `FullScreenAllowsTiling` 这类**权限标志** —— 能声明"我愿意被
///   分屏"，不能命令"现在分"。Apple 刻意让 Split View 必须由用户发起。
/// - **让 Mail 退出全屏**：`NSRunningApplication` 只能 activate / hide /
///   terminate；控制别的 App 的窗口要走 Accessibility 的 UI 脚本，是另一套权限。
///
/// 所以 Mail 全屏时，它**仍然占满整个屏幕**，我们只是盖在它右半边上面。
/// Mail 右侧那一栏（正文）会被遮住 —— 好处是切邮件仍用左边的列表。
enum WindowTiler {

    /// 「Mail 全屏时，把译文窗口贴到屏幕右半边」的开关。
    static let enabledKey = "tileWindowRightHalf"

    private static let logger = Logger(subsystem: "com.zhuyuhao.Mailingo", category: "window")

    /// 需要的话把窗口贴到右半边。由 `RootView` 在收到「点横幅」通知时调用。
    static func placeOnRightHalfIfEnabled(_ window: NSWindow) {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        // 先取得"加入别的 App 全屏空间"的资格。少了这一句，Mail 全屏时我们的
        // 窗口会被留在桌面空间里，用户切过去也看不到并排。
        var behavior = window.collectionBehavior
        behavior.insert(.canJoinAllApplications)
        window.collectionBehavior = behavior

        // 用 visibleFrame 而不是 frame：避开菜单栏和 Dock，全屏空间里它退化成
        // 整块屏幕，两种情况下都合适。
        let area = screen.visibleFrame
        let half = NSRect(
            x: area.midX,
            y: area.minY,
            width: area.width / 2,
            height: area.height
        )
        window.setFrame(half, display: true, animate: false)
        logger.notice("把窗口贴到右半边：\(Int(half.width))×\(Int(half.height)) @ \(Int(half.minX)),\(Int(half.minY))")
    }
}
