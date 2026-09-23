import SwiftUI

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
/// - 「邮件解析」是 M3 的验收界面（看管线结果）
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
    }
}
