import Cache
import SwiftUI

/// 设置窗口（菜单栏「Mailingo → 设置…」，⌘,）。
///
/// 目前只有缓存这一组 —— 也正是需要给用户可调的地方：
/// 翻译缓存会一直变大，什么时候清、清到什么程度，应该由用户定。
struct SettingsView: View {

    @AppStorage(InspectorModel.cacheMaxAgeDaysKey)
    private var maxAgeDays = CachePolicy.default.maxAgeDays

    @AppStorage(InspectorModel.cacheMaxSizeMBKey)
    private var maxSizeMB = CachePolicy.default.maxSizeMB

    /// 开发者模式。
    ///
    /// 原先只有菜单栏的「显示 → 开发者模式」（⌘⇧D）一个入口。但 Mailingo 是
    /// 附件 App（`LSUIElement`），**没有菜单栏**，那条路就断了 ——
    /// 而它恰好是排查"缓存有没有命中"的唯一入口，不能没有。
    @AppStorage(DeveloperMode.storageKey)
    private var isDeveloperMode = false

    @State private var statistics = CacheStatistics()
    @State private var message: String?

    var body: some View {
        Form {
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
                Toggle("开发者模式", isOn: $isDeveloperMode)
                Text("打开后主窗口会多出「S0 探针」页签、片段表格、缓存命中情况等诊断信息。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("诊断")
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
