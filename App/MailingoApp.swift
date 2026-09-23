import SwiftUI
import TranslationCore

@main
struct MailingoApp: App {

    /// 模型提到 App 层级：URL scheme 回调、待处理请求轮询都需要在
    /// 「根视图」这一层接住，然后驱动具体的页面。
    @StateObject private var model = InspectorModel()

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
    }
}

/// 界面骨架。
///
/// 开发者模式**不是两套界面**：这里只是决定要不要多挂一个诊断页签，
/// 页面内部再用条件分支决定多显示哪些调试面板（见 `EmailInspectionView`）。
struct RootView: View {

    @ObservedObject var model: InspectorModel

    @AppStorage(DeveloperMode.storageKey) private var isDeveloperMode = false

    /// 统一轮询：
    /// - 待处理请求文件（URL scheme 的兜底，代价只有一次 stat）
    /// - Mail 当前选中的是哪一封（只在「跟随 Mail」打开时才真的去查）
    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        pages
            // Apple Translation 在 macOS 15 上只能通过 SwiftUI 的 .translationTask 拿到
            // session，所以必须有一个挂在**真实可见窗口**里的宿主视图（方案 §4.5）。
            .appleTranslationHost()
            // Mail 扩展点击横幅后经 mailingo:// 唤醒本 App
            .onOpenURL { url in
                model.handle(url: url)
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
