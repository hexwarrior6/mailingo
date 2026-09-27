import AppKit
import Cache
import EmailCore
import SwiftUI
import Translation
import TranslationCore

/// 设置窗口（菜单栏「Mailingo → 设置…」，⌘,）。
///
/// macOS 惯例：工具栏标签页分组 —— 通用 / 翻译 / 语言包 / 缓存，
/// 每页只放一组设置。曾经全部堆在一页里，窗口高得离谱，翻找困难。
struct SettingsView: View {

    /// 各页要和主窗口共用状态，所以拿的是同一个模型。
    @ObservedObject var model: InspectorModel

    var body: some View {
        TabView {
            MailLinkageSettingsView(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }

            TranslationSettingsView(model: model)
                .tabItem { Label("翻译", systemImage: "globe") }

            LanguagePacksSettingsView(model: model)
                .tabItem { Label("语言包", systemImage: "square.and.arrow.down") }

            CacheSettingsView(model: model)
                .tabItem { Label("缓存", systemImage: "internaldrive") }
        }
        .frame(width: 480)
    }
}

// MARK: - 通用（跟 Mail 联动）

/// Mail 那边收摊了，我们也跟着收。
private struct MailLinkageSettingsView: View {

    @ObservedObject var model: InspectorModel

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }

    @AppStorage(MailActivationFollower.enabledKey)
    private var followsMailActivation = false
}

// MARK: - 翻译（引擎 / 大模型 / 图片翻译）

private struct TranslationSettingsView: View {

    @ObservedObject var model: InspectorModel

    var body: some View {
        Form {
            Section {
                Picker("翻译引擎", selection: $model.translationEngineChoice) {
                    ForEach(InspectorModel.TranslationEngineChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            } header: {
                Text("翻译引擎")
            } footer: {
                Text("「大模型」需要先在下方填好 API Key。缓存按引擎自动隔离 —— 换引擎不会互相覆盖。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            llmSection
            imageTranslationSection
        }
        .formStyle(.grouped)
        .task {
            // 已存的 Key 回显到输入框（SecureField 不回显会让用户以为没存过）
            llmAPIKeyDraft = KeychainStore.mailingo.get(InspectorModel.llmAPIKeyAccount) ?? ""
            imgtransSecretKeyDraft = KeychainStore.mailingo.get(InspectorModel.imgtransSecretKeyAccount) ?? ""
            baiduAPIKeyDraft = KeychainStore.mailingo.get(InspectorModel.baiduSecretKeyAccount) ?? ""
        }
    }

    // MARK: 大模型翻译

    /// Base URL / 模型存 UserDefaults（非密钥）；Key 存钥匙串。
    /// 字段留空时 InspectorModel 会回退到 DeepSeek 官方模板 ——
    /// 所以用户真正必须填的只有一把 Key。
    @AppStorage(InspectorModel.llmBaseURLKey) private var llmBaseURL = ""
    @AppStorage(InspectorModel.llmModelKey) private var llmModel = ""
    @State private var llmAPIKeyDraft = ""
    @State private var llmMessage: String?
    @State private var isTestingConnection = false

    private var llmSection: some View {
        Section {
            TextField("Base URL", text: $llmBaseURL, prompt: Text("留空默认 https://api.deepseek.com"))
                .autocorrectionDisabled()
            TextField("模型", text: $llmModel, prompt: Text("留空默认 deepseek-flash"))
                .autocorrectionDisabled()
            SecureField("API Key", text: $llmAPIKeyDraft, prompt: Text("sk-xxxxxxxxxxxxxxxxxxxxxxxx"))
                .onChange(of: llmAPIKeyDraft) { _, newValue in
                    KeychainStore.mailingo.set(newValue, for: InspectorModel.llmAPIKeyAccount)
                }

            HStack(spacing: 10) {
                Button("测试连接") {
                    Task { await testLLMConnection() }
                }
                .disabled(isTestingConnection)
                if isTestingConnection {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if let llmMessage {
                Text(llmMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("大模型翻译")
        } footer: {
            Text("任何 OpenAI 兼容接口都能接。两个字段都留空 = 默认走 DeepSeek 官方（https://api.deepseek.com + deepseek-flash），通常只需要填 API Key。选用「大模型」引擎后，邮件正文会发送给所配置的服务商；API Key 只存在本机钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func testLLMConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            let engine = LLMTranslationEngine(configuration: model.llmConfiguration)
            let reply = try await engine.verifyConnection()
            llmMessage = "✅ 连接成功 —— 模型回复：\(reply)"
        } catch {
            llmMessage = "❌ 连接失败：\((error as? TranslationEngineError)?.description ?? error.localizedDescription)"
        }
    }

    // MARK: 图片翻译（腾讯云 / 百度翻译）

    /// SecretId / APPID 存 UserDefaults、密钥类存钥匙串。
    /// 都没配时主界面里图片角标点了会提示去设置 —— 所以这里的字段允许先空着。
    @AppStorage(InspectorModel.imgtransSecretIDKey) private var imgtransSecretID = ""
    @State private var imgtransSecretKeyDraft = ""
    @AppStorage(InspectorModel.imgtransVendorKey) private var imgtransVendor = "tencent"
    @AppStorage(InspectorModel.baiduAppIDKey) private var baiduAppID = ""
    @State private var baiduAPIKeyDraft = ""
    @AppStorage(InspectorModel.autoTranslateImagesKey) private var autoTranslateImages = false

    private var imageTranslationSection: some View {
        Section {
            Picker("服务商", selection: $imgtransVendor) {
                Text("腾讯云（语种多）").tag("tencent")
                Text("百度翻译（每月 1000 次免费）").tag("baidu")
            }

            if imgtransVendor == "tencent" {
                TextField("SecretId", text: $imgtransSecretID, prompt: Text("AKIDxxxxxxxxxxxxxxxxxxxxxxxx"))
                    .autocorrectionDisabled()
                SecureField("SecretKey", text: $imgtransSecretKeyDraft, prompt: Text("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"))
                    .onChange(of: imgtransSecretKeyDraft) { _, newValue in
                        // 裁掉粘贴带进来的空白 —— 多一个换行签名就必挂
                        KeychainStore.mailingo.set(
                            newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                            for: InspectorModel.imgtransSecretKeyAccount
                        )
                    }
            } else {
                TextField("APP ID", text: $baiduAppID, prompt: Text("开发者后台的 APP ID"))
                    .autocorrectionDisabled()
                SecureField("API Key（密钥，存入钥匙串）", text: $baiduAPIKeyDraft, prompt: Text("粘贴控制台的 API Key"))
                    .onChange(of: baiduAPIKeyDraft) { _, newValue in
                        KeychainStore.mailingo.set(
                            newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                            for: InspectorModel.baiduSecretKeyAccount
                        )
                    }
            }

            Toggle("图片自动翻译（默认手动点图片右下角的「译」）", isOn: $autoTranslateImages)
        } header: {
            Text("图片翻译")
        } footer: {
            Text(imageTranslationFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imageTranslationFooter: String {
        let common = "两者都是「识别 + 翻译 + 渲染回整图」。打开自动翻译后，每封邮件的图片会自动逐张翻译（腾讯限频 1 次/秒）。失败原因会显示在主窗口的状态横幅上。"
        if imgtransVendor == "baidu" {
            return "百度翻译图片翻译 V2.0：每月 1000 次免费，超出按次计费。支持 20 种语种（无繁体中文 / 阿拉伯语等，遇到不支持的语种可在上方切换腾讯云）。APP ID 在「开发者信息」页，API Key 在「API Keys」页创建；两者必须来自同一账号且配对使用。" + common
        }
        return "腾讯云端到端图片翻译（lite 档）：支持 18 种语言，每月有免费额度，超出按次计费。SecretId / SecretKey 在腾讯云控制台「访问管理 → API 密钥」里创建。" + common
    }
}

// MARK: - 语言包

/// 系统语言包管理：逐语言显示安装状态，支持下载；删除没有系统接口，
/// 只能跳转系统设置（见 openSystemLanguageSettings）。
private struct LanguagePacksSettingsView: View {

    @ObservedObject var model: InspectorModel

    /// 一行 = 一个系统支持的语言 + 它的安装状态。
    private struct LanguageRow: Identifiable {
        let language: Locale.Language
        let status: LanguageAvailability.Status

        var id: String { language.minimalIdentifier }
    }

    @State private var languageRows: [LanguageRow] = []
    @State private var downloadingID: String?
    @State private var packsMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            if languageRows.isEmpty {
                VStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                // 21 个语言一行行排下去会把窗口撑到一两千点高 —— 限高滚动
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(languageRows) { packRow($0) }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(minHeight: 200, maxHeight: 430)
            }

            HStack(spacing: 10) {
                Button("刷新") {
                    Task { await refreshPacks() }
                }
                .disabled(downloadingID != nil)

                Button("在系统设置中打开…") { openSystemLanguageSettings() }

                Spacer()
            }
            .padding(.horizontal, 12)

            if let packsMessage {
                Text(packsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .frame(width: 480)
        .task { await refreshPacks() }
        .onChange(of: model.translationStatus) { oldValue, newValue in
            // 行数据是快照，而语言包还有一条**不经过本面板**的安装途径：
            // 主窗口里翻译时弹的系统下载框。所以每次翻译从「进行中」落回
            // 「空闲」（那可能刚装好一个包），就把整张表重新对一遍。
            if case .running = oldValue, case .idle = newValue {
                Task { await refreshPacks() }
            }
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
}

// MARK: - 缓存

private struct CacheSettingsView: View {

    @ObservedObject var model: InspectorModel

    @AppStorage(InspectorModel.cacheMaxAgeDaysKey)
    private var maxAgeDays = CachePolicy.default.maxAgeDays

    @AppStorage(InspectorModel.cacheMaxSizeMBKey)
    private var maxSizeMB = CachePolicy.default.maxSizeMB

    @State private var statistics = CacheStatistics()
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                ageRow
                sizeRow
            } header: {
                Text("清理规则")
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
            } header: {
                Text("占用与清理")
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onChange(of: maxAgeDays) { _, newValue in
            if newValue < 0 { maxAgeDays = 0 }
        }
        .onChange(of: maxSizeMB) { _, newValue in
            if newValue < 0 { maxSizeMB = 0 }
        }
    }

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
