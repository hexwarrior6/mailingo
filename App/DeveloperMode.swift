import SwiftUI

/// 开发者模式。
///
/// ## 为什么不是两套界面
///
/// 刻意只维护**一处布局代码**，用 `isDeveloperMode` 条件分支决定多显示哪些面板。
/// 两套界面意味着每个改动都要写两遍，必然逐渐走样。
///
/// 开关状态存在 `UserDefaults`，菜单项与各个视图都通过 `@AppStorage` 读写同一个 key，
/// 所以勾选后界面立刻跟着变，不需要额外的通知机制。
enum DeveloperMode {
    static let storageKey = "developerMode"

    /// 给非 UI 代码（例如 InspectorModel 选择引擎）读的同步快照。
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }
}

/// 菜单栏里的「开发者模式」勾选项。
///
/// 放在「显示」菜单（`.toolbar` 那一组之后）—— 它控制的是"显示多少东西"，
/// 而不是应用级设置，放这里比塞进 App 菜单更自然。
struct DeveloperModeCommands: Commands {

    @AppStorage(DeveloperMode.storageKey) private var isDeveloperMode = false

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Toggle("开发者模式", isOn: $isDeveloperMode)
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
