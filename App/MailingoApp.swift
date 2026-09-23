import SwiftUI
import TranslationCore

@main
struct MailingoApp: App {

    /// 模型提到 App 层级：URL scheme 回调、待处理请求轮询都需要在
    /// 「根视图」这一层接住，然后驱动具体的页面。
    @StateObject private var model = InspectorModel()

    var body: some Scene {
        WindowGroup("Mailingo") {
            RootView(model: model)
                // 最小尺寸放低一些，让窗口能真的缩小；内部各区域靠
                // VSplitView / HSplitView 自适应，不需要靠"大最小尺寸"兜底。
                .frame(minWidth: 820, minHeight: 520)
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
