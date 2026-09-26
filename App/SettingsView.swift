import AppKit
import Cache
import EmailCore
import SwiftUI
import Translation
import TranslationCore

/// 设置窗口（菜单栏「Mailingo → 设置…」，⌘,）。
///
/// 分组：跟 Mail 联动、翻译语言包、翻译缓存 ——
/// 都是"需要给用户可调"的地方。
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
            languagePacksSection

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
        .task { await refreshPacks() }
        .onChange(of: model.translationStatus) { oldValue, newValue in
            // 行数据是快照，而语言包还有一条**不经过本面板**的安装途径：
            // 主窗口里翻译时弹的系统下载框。所以每次翻译从「进行中」落回
            // 「空闲」（那可能刚装好一个包），就把整张表重新对一遍。
            if case .running = oldValue, case .idle = newValue {
                Task { await refreshPacks() }
            }
        }
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
    @AppStorage(MailActivationFollower.enabledKey)
    private var followsMailActivation = false

    private var mailLinkageSection: some View {
        Section {
            Toggle("跟随 Mail 一起显示 / 隐藏", isOn: $followsMailActivation)
            Text("Mail 被隐藏（右键 Dock 图标 → 隐藏，或 ⌘H）→ 我们也隐藏；"
                 + "Mail 重新显示 → 我们也显示并提到最前。\n"
                 + "提窗时**不抢键盘焦点**，Mail 仍是活动 App，照常能打字滚动。\n"
                 + "只跟随「隐藏」，不跟随「切到别的 App」—— 后者会把窗口在你查资料时收走。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    // MARK: - 翻译语言包

    /// 一行 = 一个系统支持的语言 + 它的安装状态。
    private struct LanguageRow: Identifiable {
        let language: Locale.Language
        let status: LanguageAvailability.Status

        var id: String { language.minimalIdentifier }
    }

    @State private var languageRows: [LanguageRow] = []
    @State private var downloadingID: String?
    @State private var packsMessage: String?

    private var languagePacksSection: some View {
        Section {
            if languageRows.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            } else {
                ForEach(languageRows) { packRow($0) }
            }

            HStack(spacing: 10) {
                Button("刷新") {
                    Task { await refreshPacks() }
                }
                .disabled(downloadingID != nil)

                Button("在系统设置中打开…") { openSystemLanguageSettings() }

                Spacer()
            }

            if let packsMessage {
                Text(packsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("翻译语言包")
        } footer: {
            Text("语言包由 macOS 统一管理：下载会弹出系统确认框（需要主窗口开着）；翻译时选了没装的语言也会触发下载。删除没有系统接口，只能在系统设置的「语言与地区」里进行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func packRow(_ row: LanguageRow) -> some View {
        LabeledContent {
            switch row.status {
            case .installed:
                // 装好的就是一个「勾」—— 不是下载按钮，也不该再触发下载
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("已安装")
            case .supported:
                if downloadingID == row.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("下载") {
                        Task { await download(row) }
                    }
                }
            case .unsupported:
                EmptyView()
            }
        } label: {
            Text(TranslationLanguages.displayName(for: row.language))
        }
    }

    private func refreshPacks() async {
        await model.refreshSupportedLanguages()
        let availability = LanguageAvailability()
        // status 逐语言异步查 —— 21 个语言的查询在可感知时间内能跑完
        var rows: [LanguageRow] = []
        for language in model.supportedLanguages {
            let status = await availability.status(from: language, to: nil)
            rows.append(LanguageRow(language: language, status: status))
        }
        languageRows = rows
    }

    /// 触发一个语言的下载：借 `prepareTranslation()` 弹系统的确认框。
    private func download(_ row: LanguageRow) async {
        downloadingID = row.id
        defer { downloadingID = nil }

        // 点「下载」时**先重新查一遍本地状态**：行数据是面板打开那一刻的
        // 快照，期间完全可能已经通过别的途径装好了（比如在主窗口切换语言对
        // 时弹的系统下载框里点过确认）。已装的语言再 prepare 一遍，
        // 会白白弹一次系统确认框 —— 那正是"明明装过了还让我下载"。
        let availability = LanguageAvailability()
        let current = await availability.status(from: row.language, to: nil)
        if current == .installed {
            packsMessage = "「\(TranslationLanguages.displayName(for: row.language))」已经安装过，无需重复下载。"
            await refreshPacks()
            return
        }
        guard current == .supported else {
            packsMessage = "系统不支持下载「\(TranslationLanguages.displayName(for: row.language))」的语言包。"
            await refreshPacks()
            return
        }

        // 伙伴语言：挑一个**已安装**的语言组对，系统就只会下载缺的那边；
        // 一个已安装的都没有时退回当前目标语言（缺什么系统会一起列出来）。
        let partner = languageRows
            .first { $0.status == .installed && $0.language != row.language }?
            .language ?? model.targetLanguage

        do {
            try await AppleTranslationEngine().prepare(source: row.language, target: partner)
            packsMessage = "已安装「\(TranslationLanguages.displayName(for: row.language))」。"
        } catch {
            if TranslationEngineError.isCancelledLanguagePackDownload(error) {
                packsMessage = "已取消 —— 「\(TranslationLanguages.displayName(for: row.language))」语言包尚未安装，翻译时选到它会再次弹出下载确认框。"
            } else {
                packsMessage = "下载未完成：\((error as? TranslationEngineError)?.description ?? error.localizedDescription)"
            }
        }
        await refreshPacks()
    }

    /// 删除语言包没有公开 API（macOS 15/26 都没有），只能把用户带到系统设置。
    /// 深链标识符随系统版本可能变化，失败就退回打开系统设置主面板。
    private func openSystemLanguageSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Language-Region.settings")
        if let url, NSWorkspace.shared.open(url) { return }
        _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences://")!)
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
