import SwiftUI
import TranslationCore

@main
struct MailingoApp: App {

    /// 模型提到 App 层级：URL scheme 回调、待处理请求轮询都需要在
    /// 「根视图」这一层接住，然后驱动具体的页面。
    @StateObject private var model = InspectorModel()

    /// 轻量化行为：窗口一关就退出、以及把自己激活到前台。
    /// 详见 `AppDelegate` 的注释。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 用 Window 而不是 WindowGroup：**保证只有一个窗口**。
        // WindowGroup 在 macOS 上收到 URL（例如从 Mail 点横幅过来）时
        // 有产生新窗口的行为，用户会看到"点一下翻译就多开一个窗口"。
        Window("Mailingo", id: "main") {
            RootView(model: model)
                // 最小尺寸刻意放得很低：实际用法是把 Mail 与 Mailingo
                // **并排塞进同一个全屏空间**，半屏宽约等于屏幕宽的一半
                // （本机 1470/2 ≈ 735pt），窗口必须能缩得比它更小。
                .frame(minWidth: 480, minHeight: 420)
        }
        .defaultSize(width: 1240, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            DeveloperModeCommands()
        }

        // 标准的 macOS 设置窗口：「Mailingo → 设置…」（⌘,）
        //
        // 把 model 传进去：设置里有几项（跟 Mail 联动）需要**和主窗口共用同一份
        // 状态**。若在设置里用 `@AppStorage` 直接写 UserDefaults，模型那边
        // 的属性不会跟着变，开关就成了摆设。
        Settings {
            SettingsView(model: model)
        }
    }
}

/// 界面骨架。
///
/// 开发者模式**不是两套界面**：这里只是决定要不要多挂一个诊断页签，
/// 页面内部再用条件分支决定多显示哪些调试面板（见 `EmailInspectionView`）。
struct RootView: View {

    @ObservedObject var model: InspectorModel

    /// 用来在 `applicationShouldHandleReopen` 时把主窗口叫回来
    @Environment(\.openWindow) private var openWindow
    /// 用来在 Mail 关掉阅读窗口时收掉自己。
    ///
    /// 用 `dismissWindow(id:)` 而不是 `dismiss()`：后者是"关掉当前 presentation"，
    /// 对 `Window`（单例窗口）场景语义不够明确；前者直接按 id 指名道姓地关。
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage(DeveloperMode.storageKey) private var isDeveloperMode = false

    /// 统一轮询：
    /// - 待处理请求文件（URL scheme 的兜底，代价只有一次 stat）
    /// - Mail 当前选中的是哪一封（只在「跟随 Mail」打开时才真的去查）
    ///
    /// 间隔取 0.5 秒而不是 1 秒：它是"发现你切了邮件"的**最坏延迟**，
    /// 而这一项占了跟随体验里的大头。查询本身很便宜（脚本编译一次、
    /// 之后只执行），而且只有「跟随 Mail」打开时才会真的发出 Apple Event。
    /// 前一次还没查完就发起的新查询会取代它，不会在 Mail 那边堆起来
    /// （见 `InspectorModel.pollMailSelection`）。
    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        pages
            // Apple Translation 在 macOS 15 上只能通过 SwiftUI 的 .translationTask 拿到
            // session，所以必须有一个挂在**真实可见窗口**里的宿主视图（方案 §4.5）。
            .appleTranslationHost()
            // Mail 扩展点击横幅后经 mailingo:// 唤醒本 App
            .onOpenURL { url in
                // 兜一道：App 可能已经在后台跑着，用户点了 Mail 里的横幅
                // 却没看到窗口浮上来 —— 那这个功能就等于没反应。
                AppDelegate.activate()
                model.handle(url: url)
            }
            // 在跑但主窗口已关（比如设置窗口还开着）时，用户又点了一次图标
            .onReceive(NotificationCenter.default.publisher(for: .mailingoReopenMainWindow)) { _ in
                openWindow(id: "main")
            }
            // Mail 关掉阅读窗口 → 也把自己收掉（窗口一关，App 就跟着退出）
            .onReceive(NotificationCenter.default.publisher(for: .mailingoCloseMainWindow)) { _ in
                dismissWindow(id: "main")
            }
            .onReceive(pollTimer) { _ in
                model.pollPendingRequest()
                model.pollMailSelection()
            }
            // 关掉开发者模式时，如果当前选的是调试用引擎，要切回正式引擎重翻一次
            .onChange(of: isDeveloperMode) { _, _ in
                model.developerModeDidChange()
            }
            .task {
                await model.bootstrap()
            }
    }

    @ViewBuilder
    private var pages: some View {
        if isDeveloperMode {
            TabView {
                EmailInspectionView(model: model)
                    .tabItem { Label("邮件解析", systemImage: "doc.text.magnifyingglass") }

                ProbeLogView()
                    .tabItem { Label("S0 探针", systemImage: "wrench.and.screwdriver") }
            }
            .padding(.top, 4)
        } else {
            // 正常使用：只有一个页面，不必套 TabView
            // （单页签的 TabView 在 macOS 上会多出一条没有意义的页签栏）
            EmailInspectionView(model: model)
        }
    }
}
