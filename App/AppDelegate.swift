import AppKit

extension Notification.Name {
    /// 「把主窗口重新打开」。
    ///
    /// 为什么用通知而不是直接开窗：主窗口是 SwiftUI 的 `Window` 场景，
    /// 由 SwiftUI 管生命周期，AppKit 这边造不出一个属于该场景的窗口。
    /// 所以 AppDelegate 只能发个通知，让 SwiftUI 那边用 `openWindow` 去开。
    static let mailingoReopenMainWindow = Notification.Name("com.zhuyuhao.Mailingo.reopenMainWindow")
}

/// 轻量化相关的应用级行为。
///
/// 产品形态是「Mail 点一下才出现的那块译文面板」，不是一个常驻应用。
/// 所以这里两件事：
///
/// 1. **窗口一关就退出**，不留后台进程、不占内存。
/// 2. **主动把自己激活到前台**。附件 App（`LSUIElement`）不会被系统自动
///    激活 —— 从 Mail 横幅唤起时窗口会开在 Mail 后面，用户以为没反应。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 最后一个窗口关掉就退出。
    ///
    /// 注意"最后一个"：如果设置窗口开着，关掉主窗口不会退出 —— 那是对的，
    /// 用户还在用这个 App。两个都关掉才走。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activate()
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

    /// 附件 App 不会自动到前台，得自己喊一声。
    static func activate() {
        NSApp.activate()
    }

    private func activate() {
        Self.activate()
    }
}
