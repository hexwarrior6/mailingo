import AppKit
import SwiftUI

/// 容器 App 的探针看板。
///
/// 扩展是独立进程，你没法在它里面下断点；所以这个窗口把 `~/Library/Logs/Mailingo/probe.log`
/// 实时读出来，并按 S0 的 4 个问题自动判定通过与否。
struct ProbeLogView: View {

    @State private var log = ""
    @State private var lastMessageSize: Int?
    @State private var lastRefresh = Date()

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            checklist
            Divider()
            logView
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("S0：Mail 扩展能否成为翻译入口与数据源")
                .font(.headline)
            Text("日志目录：\(ProbeLog.directory.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("刷新", action: refresh)
                Button("打开日志目录") {
                    NSWorkspace.shared.open(ProbeLog.directory)
                }
                Button("清空日志") {
                    ProbeLog.shared.clear()
                    refresh()
                }
                Button(returnNilFlagExists ? "开关：当前 return nil（基线）" : "开关：当前返回非 nil") {
                    toggleReturnNilFlag()
                    refresh()
                }
                .help("切换 decodedMessage 是否返回非 nil。改完无需重装扩展或重启 Mail，去 Mail 里重新点一封邮件即可。")
                Spacer()
                Text("每 2 秒自动刷新 · 更新于 \(lastRefresh.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }

    // MARK: - S0 判定清单

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            check(
                "1. 扩展被 Mail 加载",
                log.contains("MailingoMailExtension 已实例化"),
                "Mail → 设置 → 扩展 里启用 Mailingo，然后重启 Mail"
            )
            check(
                "2. 普通邮件也调用了 decodedMessage(forMessageData:)",
                log.contains("decodedMessage(forMessageData:) 被调用"),
                "打开几封**普通未加密**邮件，再回来看这里"
            )
            check(
                "3. 横幅渲染 + 点击后 Mail 呈现了我们的视图控制器",
                log.contains("extensionViewController") || log.contains("primaryActionClicked"),
                "回 Mail 点邮件顶部的「翻译」横幅或头部图标"
            )
            check(
                "4. 拿到的是完整原始 MIME",
                (lastMessageSize ?? 0) > 64,
                lastMessageSize.map { "已落盘 \($0) bytes → \(ProbeLog.lastMessageURL.path)" }
                    ?? "还没拿到数据"
            )
        }
        .padding(16)
    }

    private func check(_ title: String, _ passed: Bool, _ hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(passed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: passed ? .semibold : .regular))
                if !passed {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 日志

    private var logView: some View {
        ScrollView {
            Text(log.isEmpty ? "（日志为空 —— 还没收到任何事件）" : log)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - 状态

    private var returnNilFlagExists: Bool {
        FileManager.default.fileExists(
            atPath: ProbeLog.directory.appendingPathComponent("return-nil").path
        )
    }

    private func toggleReturnNilFlag() {
        let url = ProbeLog.directory.appendingPathComponent("return-nil")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    private func refresh() {
        log = ProbeLog.shared.readLog()
        lastMessageSize = (try? Data(contentsOf: ProbeLog.lastMessageURL))?.count
        lastRefresh = Date()
    }
}

#Preview {
    ProbeLogView()
}
