import SwiftUI
import TranslationCore

@main
struct MailingoApp: App {
    var body: some Scene {
        WindowGroup("Mailingo") {
            RootView()
                .frame(minWidth: 1000, minHeight: 640)
        }
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
    var body: some View {
        TabView {
            EmailInspectionView()
                .tabItem { Label("邮件解析", systemImage: "doc.text.magnifyingglass") }

            ProbeLogView()
                .tabItem { Label("S0 探针", systemImage: "wrench.and.screwdriver") }
        }
        .padding(.top, 4)
        // Apple Translation 在 macOS 15 上只能通过 SwiftUI 的 .translationTask 拿到
        // session，所以必须有一个挂在**真实可见窗口**里的宿主视图（方案 §4.5）。
        .appleTranslationHost()
    }
}
