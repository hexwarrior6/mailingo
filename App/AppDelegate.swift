import AppKit

extension Notification.Name {
    /// 「把主窗口重新打开」。
    ///
    /// 为什么用通知而不是直接开窗：主窗口是 SwiftUI 的 `Window` 场景，
    /// 由 SwiftUI 管生命周期，AppKit 这边造不出一个属于该场景的窗口。
    /// 所以 AppDelegate 只能发个通知，让 SwiftUI 那边用 `openWindow` 去开。
    static let mailingoReopenMainWindow = Notification.Name("com.zhuyuhao.Mailingo.reopenMainWindow")

    /// 「把主窗口贴到屏幕右半边」。用户点了 Mail 里的「翻译」横幅时发。
    static let mailingoPlaceWindowOnRightHalf = Notification.Name("com.zhuyuhao.Mailingo.placeWindowOnRightHalf")

    /// 「把主窗口收掉」。用户开了「Mail 关掉阅读窗口时同时关闭 Mailingo」，
    /// 而 Mail 那边的阅读窗口确实不见了。
    ///
    /// 同样是 SwiftUI 的 Window 场景归它自己管，AppKit 关不了，
    /// 只能发通知让 RootView 用 `dismiss()` 收。
    static let mailingoCloseMainWindow = Notification.Name("com.zhuyuhao.Mailingo.closeMainWindow")
}

/// 轻量化相关的应用级行为。
///
/// ## 形态：常规 App + 关窗即退出
///
/// Dock 图标和菜单栏都**保留**（所以 ⌘, 设置、⌘⇧D 开发者模式照常可用），
/// 轻量化靠的是"窗口一关就退出"—— 不是隐藏 Dock 图标。
///
/// 这条区别是有代价教训的：早先试过 `LSUIElement`，它会把菜单栏一起带走，
/// 于是设置和开发者模式都得另找地方放。而"关窗即退出"本来就足以让
/// 不用它的时候不占内存，没必要再牺牲菜单栏。
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 「Mail 到前台 → 我们的窗口也提到最前」。
        // 挂观察者本身不需要权限，是否生效由设置里的开关决定。
        MailActivationFollower.shared.start()
    }

    /// 最后一个窗口关掉就退出，不留后台进程。
    ///
    /// 注意是"最后一个"：设置窗口开着时关掉主窗口不会退出 —— 那是对的，
    /// 用户还在用这个 App。两个都关掉才走。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 已经在运行、用户又点了它一次（Finder / Spotlight / Launchpad）。
    ///
    /// 正常路径下不会出现"在跑但没窗口"——那状态会直接退出。但设置窗口开着
    /// 时不退，这时主窗口可能已经关了，所以要能把主窗口叫回来。
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .mailingoReopenMainWindow, object: nil)
        }
        activate()
        return true
    }

    /// 把自己激活到前台。
    ///
    /// 常规 App 通常由系统负责激活，这里只在收到 `mailingo://` 时兜一道：
    /// 万一 App 已经在后台跑着，用户点了 Mail 里的横幅却没看到窗口浮上来，
    /// 那这个功能就等于没反应。
    static func activate() {
        NSApp.activate()
    }

    private func activate() {
        Self.activate()
    }
}
