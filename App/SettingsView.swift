import AppKit
import Cache
import EmailCore
import SwiftUI
import Translation
import TranslationCore

/// 设置窗口（菜单栏「Mailingo → 设置…」，⌘,）。
///
/// macOS 惯例：工具栏标签页分组 —— 通用 / 翻译 / 缓存，
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
                // 扁平分段子标签：**点哪个就把翻译引擎设成哪个**
                Picker("", selection: $model.translationEngineChoice) {
                    Text("Apple 翻译").tag(InspectorModel.TranslationEngineChoice.apple)
                    Text("大模型翻译").tag(InspectorModel.TranslationEngineChoice.llm)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.translationEngineChoice {
                case .apple:
                    applePane
                case .llm:
                    llmPane
                }
            } header: {
                Text("文本翻译")
            } footer: {
                Text(translationFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            imageTranslationSection
        }
        .formStyle(.grouped)
        .task {
            // 已存密钥回显到输入框（SecureField 不回显会让用户以为没存过）+
            // 语言包清单加载（Apple 子页要用）
            llmAPIKeyDraft = KeychainStore.mailingo.get(InspectorModel.llmAPIKeyAccount) ?? ""
            imgtransSecretKeyDraft = KeychainStore.mailingo.get(InspectorModel.imgtransSecretKeyAccount) ?? ""
            baiduAPIKeyDraft = KeychainStore.mailingo.get(InspectorModel.baiduSecretKeyAccount) ?? ""
            await refreshPacks()
        }
        .onChange(of: model.translationStatus) { oldValue, newValue in
            // 语言包行数据是快照：翻译落回空闲（可能刚装好一个语言包）时重新对表
            let wasBusy: Bool = {
                if case .running = oldValue { return true }
                if case .imageRunning = oldValue { return true }
                return false
            }()
            if wasBusy, case .idle = newValue {
                Task { await refreshPacks() }
            }
        }
    }

    /// 文本翻译区块的页脚，随子页变化。
    private var translationFooter: String {
        switch model.translationEngineChoice {
        case .apple:
            return "语言包下载会弹出系统确认框；删除语言包没有系统接口，只能到系统设置操作。"
        case .llm:
            return "任何 OpenAI 兼容接口都能接。选用后邮件正文会发送给所配置的服务商；API Key 只存本机钥匙串。"
        }
    }

    // MARK: - Apple 翻译子页（语言包管理）

    /// 弹出式语言管理窗口的开关。
    @State private var isShowingLanguageManager = false

    /// 一行 = 一个系统支持的语言 + 它的安装状态。
    private struct LanguageRow: Identifiable {
        let language: Locale.Language
        let status: LanguageAvailability.Status

        var id: String { language.minimalIdentifier }
    }

    @State private var languageRows: [LanguageRow] = []
    @State private var downloadingID: String?
    @State private var packsMessage: String?

    private var applePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("语言包已装齐的语种可直接翻译；缺的会在这里下载。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("管理语言包…") {
                    Task { await refreshPacks() }
                    isShowingLanguageManager = true
                }
                .popover(isPresented: $isShowingLanguageManager, arrowEdge: .bottom) {
                    languageManagerPopover
                }

                Spacer()
            }

            if let installedSummary {
                Text(installedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 弹出窗口里的语言列表：原生样式（名称居左、状态/按钮居右、
    /// 系统行距），限宽限高滚动。
    private var languageManagerPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("语言包").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("刷新") {
                    Task { await refreshPacks() }
                }
                .disabled(downloadingID != nil)
                .controlSize(.small)
                Button("在系统设置中打开…") { openSystemLanguageSettings() }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if languageRows.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(languageRows) { row in
                            packRow(row)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            Divider()
                                .padding(.horizontal, 10)
                        }
                    }
                }
                .frame(width: 300, height: 340)
            }

            if let packsMessage {
                Divider()
                Text(packsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var installedSummary: String? {
        guard !languageRows.isEmpty else { return nil }
        let installed = languageRows.filter { $0.status == .installed }.count
        let total = languageRows.filter { $0.status != .unsupported }.count
        return "已下载 \(installed) / 共 \(total) 种语言"
    }

    private func packRow(_ row: LanguageRow) -> some View {
        HStack {
            Text(TranslationLanguages.displayName(for: row.language))
            Spacer()
            switch row.status {
            case .installed:
                Text("已下载")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .supported:
                if downloadingID == row.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("下载") {
                        Task { await download(row) }
                    }
                    .controlSize(.small)
                }
            case .unsupported:
                EmptyView()
            }
        }
    }

    private func refreshPacks() async {
        await model.refreshSupportedLanguages()
        let availability = LanguageAvailability()
        var rows: [LanguageRow] = []
        for language in model.supportedLanguages {
            let status = await availability.status(from: language, to: nil)
            rows.append(LanguageRow(language: language, status: status))
        }
        languageRows = rows
    }

    /// 点「下载」时**先重新查一遍本地状态**（行数据是面板快照，期间可能已
    /// 通过别的途径装好），已装的不弹系统框。
    private func download(_ row: LanguageRow) async {
        downloadingID = row.id
        defer { downloadingID = nil }

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

        // 伙伴语言：挑一个已安装的语言组对，系统就只下载缺的那边
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

    /// 删除语言包没有公开 API —— 只能跳系统设置。
    ///
    /// 两个坑：
    /// 1. Ventura 起「语言与地区」是一个 Settings 扩展，面板 ID 是
    ///    `com.apple.Localization-Settings.extension`（扩展 Info.plist 里的
    ///    `legacyBundleIdentifier` 是 `com.apple.Localization`）。
    ///    之前写的 `com.apple.Language-Region.settings` 并不存在 ——
    ///    `NSWorkspace.open` 对这种 URL 照样返回 true（LaunchServices 只是把
    ///    系统设置 App 拉起来），结果是打开一个没选中任何面板的空窗口，
    ///    所以「兜底」也永远轮不到。
    /// 2. 光打开面板还停在「语言与地区」，用户得自己找「翻译语言…」按钮。
    ///    挂上 `?translation` 锚点会直接把「可供下载的语言」那张表弹出来 ——
    ///    也就是系统里真正管理语言包的地方。
    private func openSystemLanguageSettings() {
        let deepLink = "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation"
        if let url = URL(string: deepLink), NSWorkspace.shared.open(url) { return }
        // 连系统设置都拉不起来时的兜底：只打开 App 本身。
        _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences://")!)
    }

    // MARK: - 大模型翻译子页

    /// Base URL / 模型存 UserDefaults（非密钥）；Key 存钥匙串。
    /// 字段留空时回退 DeepSeek 官方模板 —— 用户必填的只有一把 Key。
    @AppStorage(InspectorModel.llmBaseURLKey) private var llmBaseURL = ""
    @AppStorage(InspectorModel.llmModelKey) private var llmModel = ""
    @State private var llmAPIKeyDraft = ""
    @State private var llmMessage: String?
    @State private var isTestingConnection = false

    private var llmPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Base URL", text: $llmBaseURL, prompt: Text("留空默认 https://api.deepseek.com"))
                .autocorrectionDisabled()
            TextField("模型", text: $llmModel, prompt: Text("留空默认 deepseek-flash"))
                .autocorrectionDisabled()
            SecureField("API Key", text: $llmAPIKeyDraft, prompt: Text("sk-xxxxxxxxxxxxxxxxxxxxxxxx"))
                .onChange(of: llmAPIKeyDraft) { _, newValue in
                    KeychainStore.mailingo.set(
                        newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                        for: InspectorModel.llmAPIKeyAccount
                    )
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

            Toggle("图片自动翻译（默认手动点图片右下角的「文A」）", isOn: $autoTranslateImages)
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
