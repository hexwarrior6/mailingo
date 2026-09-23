import Cache
import SwiftUI

/// 设置窗口（菜单栏「Mailingo → 设置…」，⌘,）。
///
/// 目前只有缓存这一组 —— 也正是需要给用户可调的地方：
/// 翻译缓存会一直变大，什么时候清、清到什么程度，应该由用户定。
struct SettingsView: View {

    /// 跟 Mail 联动的那几项要和主窗口共用状态，所以拿的是同一个模型。
    @ObservedObject var model: InspectorModel

    @AppStorage(InspectorModel.cacheMaxAgeDaysKey)
    private var maxAgeDays = CachePolicy.default.maxAgeDays

    @AppStorage(InspectorModel.cacheMaxSizeMBKey)
    private var maxSizeMB = CachePolicy.default.maxSizeMB

    @State private var statistics = CacheStatistics()
    @State private var message: String?

    var body: some View {
        Form {
            mailLinkageSection

            Section {
                ageRow
                sizeRow
            } header: {
                Text("翻译缓存")
            } footer: {
                Text("同一封邮件只翻译一次。缓存按「最近使用时间」淘汰 —— 常用的不会因为放得久就被删。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("当前占用") {
                    Text(usageDescription)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("立即清理") {
                        Task { await purgeNow() }
                    }
                    Button("清空全部缓存", role: .destructive) {
                        Task { await removeAll() }
                    }
                    Spacer()
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await refresh() }
        .onChange(of: maxAgeDays) { _, newValue in
            if newValue < 0 { maxAgeDays = 0 }
        }
        .onChange(of: maxSizeMB) { _, newValue in
            if newValue < 0 { maxSizeMB = 0 }
        }
    }

    // MARK: - 跟 Mail 联动

    /// Mail 那边收摊了，我们也跟着收。
    ///
    /// 检测信号来自「跟随 Mail」的轮询 —— Mail 的 AppleScript 会区分
    /// 「没有阅读窗口」和「没选中邮件」，前者正是我们要的。所以这个开关
    /// **依赖「跟随 Mail」**，没开跟随就没有信号，只能置灰。
    private var mailLinkageSection: some View {
        Section {
            Toggle("Mail 关掉阅读窗口时，同时关闭 Mailingo", isOn: $model.closesWithMail)
                .disabled(!model.followsMailSelection)

            Text(model.followsMailSelection
                 ? "窗口关掉后 App 会一并退出，下次从 Mail 的横幅重新唤起。"
                 : "需要先在主窗口打开「跟随 Mail」—— 检测信号来自它的轮询。")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 只在上面那个开关打开时才出现 —— 关了它，这一项没有意义
            if model.closesWithMail {
                Toggle("立即关闭，不等确认", isOn: $model.closesWithMailImmediately)
                    .disabled(!model.followsMailSelection)

                Text(model.closesWithMailImmediately
                     ? "识别到 Mail 的阅读窗口没了就立刻关。万一 Mail 一时报不出窗口，Mailingo 会当场消失。"
                     : "默认会连续确认约 1.5 秒，避免 Mail 一瞬间报不出窗口就把 Mailingo 收掉。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("跟 Mail 联动")
        }
    }

    // MARK: - 清理规则

    private var ageRow: some View {
        LabeledContent("保留天数") {
            HStack(spacing: 6) {
                TextField("", value: $maxAgeDays, format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Stepper("", value: $maxAgeDays, in: 0...3650)
                    .labelsHidden()
                Text(maxAgeDays == 0 ? "天（不按时间清理）" : "天未使用即清理")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sizeRow: some View {
        LabeledContent("大小上限") {
            HStack(spacing: 6) {
                TextField("", value: $maxSizeMB, format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Stepper("", value: $maxSizeMB, in: 0...10_000, step: 50)
                    .labelsHidden()
                Text(maxSizeMB == 0 ? "MB（不限制大小）" : "MB，超出则淘汰最久未用的")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var usageDescription: String {
        String(format: "%.1f MB · %d 条", statistics.totalMegabytes, statistics.entryCount)
    }

    // MARK: - 动作

    private func refresh() async {
        statistics = await TranslationCache.shared.statistics()
    }

    private func purgeNow() async {
        let policy = CachePolicy(maxAgeDays: maxAgeDays, maxSizeMB: maxSizeMB)
        let result = await TranslationCache.shared.purge(policy: policy)
        await refresh()
        message = result.removedTotal == 0
            ? "没有需要清理的缓存。"
            : String(format: "已清理 %d 条，释放 %.1f MB。", result.removedTotal, Double(result.freedBytes) / 1_048_576)
    }

    private func removeAll() async {
        let removed = await TranslationCache.shared.removeAll()
        await refresh()
        message = "已清空 \(removed) 条缓存。"
    }
}
