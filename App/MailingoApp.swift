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
        // 产品形态是固定单窗口（将来译文侧栏是独立的 NSPanel），
        // 所以单实例 Window 才是对的。
        Window("Mailingo", id: "main") {
            RootView(model: model)
                // 最小尺寸刻意放得很低：实际用法是把 Mail 与 Mailingo
                // **并排塞进同一个全屏空间**，半屏宽约等于屏幕宽的一半
                // （本机 1470/2 ≈ 735pt），窗口必须能缩得比它更小。
                // 内部各区域靠 VSplitView / HSplitView 自适应，
                // 工具栏在窄宽度下会折成两行（ViewThatFits）。
                .frame(minWidth: 480, minHeight: 420)
        }
        .defaultSize(width: 1240, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// 两个页签：
/// - 「邮件解析」是 M3/M4 的验收界面（看管线与翻译结果）
/// - 「S0 探针」是上一阶段留下的诊断看板，排障时还会用到
struct RootView: View {

    @ObservedObject var model: InspectorModel

    /// 兜底轮询：容器 App 可能已经在运行，这时 LaunchServices 打开 URL
    /// 未必能把请求送进来；appex 又是沙盒进程，打开 URL 有失败的可能。
    /// 每 1.5 秒看一眼请求文件，代价只有一次 stat。
    private let pendingRequestTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            EmailInspectionView(model: model)
                .tabItem { Label("邮件解析", systemImage: "doc.text.magnifyingglass") }

            ProbeLogView()
                .tabItem { Label("S0 探针", systemImage: "wrench.and.screwdriver") }
        }
        .padding(.top, 4)
        // Apple Translation 在 macOS 15 上只能通过 SwiftUI 的 .translationTask 拿到
        // session，所以必须有一个挂在**真实可见窗口**里的宿主视图（方案 §4.5）。
        .appleTranslationHost()
        // Mail 扩展点击横幅后经 mailingo:// 唤醒本 App
        .onOpenURL { url in
            model.handle(url: url)
        }
        .onReceive(pendingRequestTimer) { _ in
            model.pollPendingRequest()
        }
        .task {
            await model.bootstrap()
        }
    }
}
