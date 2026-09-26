import EmailCore
import SwiftUI
import TranslationCore
import UniformTypeIdentifiers

/// M3/M4 的验收界面：把「解析结果」和「翻译结果」直接摆出来。
///
/// 左边是原文渲染，右边是切片后的渲染。切到「Apple 翻译」时右边就是**真中文**；
/// 切到「标记替换」时每个文本节点变成 `〖N〗`，用来看清哪些节点被碰过。
struct EmailInspectionView: View {

    @ObservedObject var model: InspectorModel

    /// 语言对菜单里「管理语言包…」要打开设置窗口。
    @Environment(\.openSettings) private var openSettings

    @State private var isImporting = false
    @AppStorage("inspector.showSegments") private var isSegmentsVisible = true
    @AppStorage("inspector.displayMode") private var displayMode: DisplayMode = .bilingual
    /// 开发者模式：只影响「多显示哪些调试面板」，不影响布局代码本身。
    @AppStorage(DeveloperMode.storageKey) private var isDeveloperMode = false
    /// 是否加载外部图片。默认**关闭** —— 远程图片是最常见的追踪手段，
    /// 发件人靠它知道你什么时候、看了几次。和 Mail 的行为一致。
    @AppStorage(InspectorModel.allowsRemoteContentKey) private var allowsRemoteContent = false

    /// 看什么：只看原文 / 只看译文 / 双语并排。
    ///
    /// 单独看某一侧在窄窗口（并排放在半屏时）里特别有用 ——
    /// 两个窗格各占一半会把邮件挤得很窄。
    enum DisplayMode: String, CaseIterable, Identifiable {
        case original
        case translated
        case bilingual

        var id: String { rawValue }

        var label: String {
            switch self {
            case .original: "原文"
            case .translated: "译文"
            case .bilingual: "双语"
            }
        }

        var symbol: String {
            switch self {
            case .original: "doc.plaintext"
            case .translated: "character.book.closed"
            case .bilingual: "rectangle.split.2x1"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            statusBanner

            switch model.state {
            case .idle:
                placeholder("点「刷新」或从左上角选择一封邮件开始。")
            case .loading:
                placeholder("解析中…")
            case .failed(let message):
                placeholder(message, isError: true)
            case .loaded:
                if let inspection = model.inspection {
                    content(inspection)
                } else {
                    placeholder("解析完成，但没有内容。")
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "eml") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.load(fileURL: url) }
            }
        }
    }

    // MARK: - 顶部

    private var toolbar: some View {
        // 并排使用时窗口会很窄，固定一行放不下 —— ViewThatFits 会自动折成两行。
        // 语言对菜单固定**右对齐**：它是"现在翻成什么"的状态，放右边
        // 与网页翻译的习惯一致，也不跟左侧的邮件选择挤在一起。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                toolbarLeading
                if isDeveloperMode {
                    Divider().frame(height: 16)
                    toolbarTrailing
                }
                Spacer(minLength: 0)
                languagePairMenu
            }
            .padding(12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { toolbarLeading; Spacer(minLength: 0); languagePairMenu }
                if isDeveloperMode {
                    HStack(spacing: 10) { toolbarTrailing; Spacer(minLength: 0) }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var toolbarLeading: some View {
        messagePicker

        Button {
            // 必须**绕过缓存**：有缓存时普通重翻是个空操作，
            // 用户就没法纠正一个翻坏的译文了。
            Task { await model.retranslate() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("重新读取并重新翻译（忽略缓存）")

        // 「打开 .eml」是调试用的（喂自造样本），正常使用不需要
        if isDeveloperMode {
            Button("打开 .eml…") { isImporting = true }
        }
    }

    /// 翻译语言对：源语言可自动检测，也可手动指定 —— 跟网页翻译一致。
    ///
    /// 手动钉住源语言同时是绕过自动检测误判的手段：检测器认错时
    /// （英文邮件被认成挪威语之类），钉一下就绕过去了。
    private var languagePairMenu: some View {
        Menu {
            Picker("源语言", selection: $model.sourceLanguage) {
                Text("自动检测").tag(Locale.Language?.none)
                ForEach(model.supportedLanguages, id: \.self) { language in
                    Text(TranslationLanguages.displayName(for: language))
                        .tag(Optional(language))
                }
            }
            Picker("目标语言", selection: $model.targetLanguage) {
                ForEach(model.supportedLanguages, id: \.self) { language in
                    Text(TranslationLanguages.displayName(for: language))
                        .tag(language)
                }
            }
            Divider()
            Button("管理语言包…") { openSettings() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(languagePairLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // 超长（钉住的语言名很长）才截断；平时按内容收缩，文字紧贴右侧
            .frame(maxWidth: 150, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        // 必须水平 fixedSize：HStack 里有个 Spacer，水平可伸缩的控件会被
        // 撑到几百 pt —— 文字（左）和下拉箭头（右）中间空出一大圈。
        // 收缩到内容大小后，文字才真正贴着右边缘。
        .fixedSize(horizontal: true, vertical: true)
        .help("翻译语言对：\(languagePairDescription)。目标语言包没装时，首次翻译会弹出系统下载确认。")
    }

    /// 菜单标签上的**紧凑**写法：默认（自动检测）只显示目标语言 ——
    /// 源语言是自动检测这件事不用占着工具栏；钉住了源语言才亮出来，
    /// 因为那是个少见的纠偏动作，藏起来反而让人忘了它是钉着的。
    private var languagePairLabel: String {
        guard let source = model.sourceLanguage else {
            return TranslationLanguages.displayName(for: model.targetLanguage)
        }
        return "\(TranslationLanguages.displayName(for: source)) → \(TranslationLanguages.displayName(for: model.targetLanguage))"
    }

    /// 完整写法（给 tooltip）：源为自动检测时明确说"自动检测"。
    private var languagePairDescription: String {
        let source = model.sourceLanguage.map { TranslationLanguages.displayName(for: $0) } ?? "自动检测"
        return "\(source) → \(TranslationLanguages.displayName(for: model.targetLanguage))"
    }

    /// 只有开发者模式才有的控件：切引擎、跑自检。
    @ViewBuilder
    private var toolbarTrailing: some View {
        Picker("引擎", selection: $model.engineChoice) {
            ForEach(InspectorModel.EngineChoice.allCases) { choice in
                Text(choice.label).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)

        Button("翻译自检") {
            Task { await model.runDiagnostics(allowDownloadTrigger: true) }
        }
        .help("跑一遍完整翻译并写入 translation-selftest.log。语言包未安装时会触发系统下载确认。")
    }

    /// 会话（来回好几封回复）里从这里选具体是哪一封。
    private var messagePicker: some View {
        Menu {
            if model.capturedMessages.isEmpty {
                Text("还没有捕获到邮件")
            } else {
                ForEach(model.capturedMessages) { message in
                    Button {
                        Task { await model.load(messageID: message.id) }
                    } label: {
                        Text("\(message.displayTitle) — \(shortSender(message.from))")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "envelope")
                Text(model.currentMessage?.displayTitle ?? "选择邮件")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.capturedMessages.count > 1 {
                    Text("(\(model.capturedMessages.count))")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 120, idealWidth: 260, maxWidth: 320, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("已捕获的邮件。会话里来回好几封都会列在这里。")
    }

    private func shortSender(_ from: String) -> String {
        // "Name <a@b.c>" → "Name"；只有地址就原样返回
        if let angle = from.firstIndex(of: "<") {
            return from[from.startIndex..<angle].trimmingCharacters(in: .whitespaces)
        }
        return from
    }

    // MARK: - 翻译状态

    @ViewBuilder
    private var statusBanner: some View {
        switch model.translationStatus {
        case .idle:
            EmptyView()

        case .running(let done, let total):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("翻译中 \(done)/\(total)").font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.08))

        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).textSelection(.enabled)
                Spacer()
                // 失败横幅以前没有任何动作入口 —— 比如语言对不支持时，
                // 用户得自己反应过来去工具栏换语言。给个直达的重试。
                Button("重试") {
                    Task { await model.retranslate() }
                }
                .font(.caption)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.10))
        }
    }

    // MARK: - 主体

    private func content(_ inspection: EmailInspection) -> some View {
        VStack(spacing: 0) {
            summaryBar(inspection)
            Divider()
            displayModeBar
            Divider()
            mailFollowNotice
            remoteContentNotice(inspection)

            // VSplitView：中间那条分隔线可以**上下拖拽**，用来调整
            // 「原文 / 译文」预览区的高度 —— 长邮件里这是最需要能调的一块。
            // 折叠时把表格整个撤掉，预览区自然占满剩余空间。
            // 「提取出的片段」是调试面板：正常使用完全不需要看到它
            if isDeveloperMode, isSegmentsVisible {
                VSplitView {
                    previews(inspection)
                        .frame(minHeight: 160)
                    segmentsTable(inspection)
                        .frame(minHeight: 96)
                }
            } else {
                previews(inspection)
            }

            if isDeveloperMode {
                Divider()
                // 折叠条固定在窗口底部：展开还是折叠都停在同一位置，不会跳。
                segmentsToggleBar(count: inspection.segments.count)
            }
        }
    }

    /// 显示模式切换条。
    ///
    /// 放在预览区正上方而不是挤进工具栏：工具栏已经够满了，
    /// 而这个开关只影响下面这块内容，挨着放更好找。
    private var displayModeBar: some View {
        HStack(spacing: 10) {
            Picker("显示", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Text(displayModeHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 0)

            followMailToggle
            remoteContentToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 「跟随 Mail」出问题时的提示。
    ///
    /// 权限被拒**必须**说出来：否则用户打开了开关却毫无反应，只能干等。
    @ViewBuilder
    private var mailFollowNotice: some View {
        switch model.mailFollowStatus {
        case .off, .following:
            EmptyView()

        case .waiting(let reason):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(reason).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.06))

        case .permissionDenied:
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要「自动化」权限才能跟随 Mail").font(.caption)
                    Text("系统设置 → 隐私与安全性 → 自动化 → 勾选 Mailingo")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("打开系统设置") { model.openAutomationSettings() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.10))

        case .failed(let reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).font(.caption).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.10))
        }
    }

    /// 外部图片被拦截时的提示条。
    ///
    /// 这一条不是装饰，是**必需**的：真实案例里，一封营销邮件把 emoji 做成了远程图片
    /// （`<img alt="🌍" src="https://…/1f30d.png">`），拦截之后那几个 emoji 凭空消失，
    /// 而同封邮件里真正的文字 emoji（📅📍）还正常显示 ——
    /// 用户看到的就是"有些 emoji 显示不出来"，根本猜不到是图片被拦了。
    ///
    /// 明说「已拦截 N 张外部图片」并给一键载入，才对得上 Mail 的行为。
    @ViewBuilder
    private func remoteContentNotice(_ inspection: EmailInspection) -> some View {
        let count = RemoteContentScanner.remoteImageCount(in: inspection.originalHTML)
        if !allowsRemoteContent, count > 0 {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("这封邮件包含 \(count) 张外部图片，已拦截 —— 发件人可通过它们得知你何时、看了几次")
                    .font(.caption)
                Spacer(minLength: 8)
                Button("载入图片") { allowsRemoteContent = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.10))
            Divider()
        }
    }

    /// 跟随 Mail 的选中项自动切换。
    ///
    /// 需要「自动化」权限 —— 第一次打开会弹系统授权框。
    /// 这是唯一能**精确**知道"用户在看哪一封"的办法：Mail 只推邮件内容，
    /// 不推"当前选中项"，而被动解码事件里有大量批量解码噪声。
    private var followMailToggle: some View {
        Toggle(isOn: $model.followsMailSelection) {
            Label("跟随 Mail", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help("打开后，你在 Mail 里点开哪一封，这里就自动切到那一封并翻译（需要授权「自动化」）")
    }

    /// 是否加载外部图片。
    ///
    /// 默认**不加载**：远程图片是最常见的追踪手段（发件人靠它知道你何时、看了几次），
    /// 而且加载失败时邮件排版会缺图。需要时手动点一下。
    private var remoteContentToggle: some View {
        Toggle(isOn: $allowsRemoteContent) {
            Label(
                allowsRemoteContent ? "已载入远程图片" : "载入远程图片",
                systemImage: allowsRemoteContent ? "photo.badge.checkmark" : "photo.badge.exclamationmark"
            )
            .font(.caption)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(allowsRemoteContent
              ? "远程图片已载入。关闭可恢复拦截（发件人将无法通过图片得知你已阅读）"
              : "邮件默认不加载外部图片，以免发件人通过追踪像素得知你已阅读")
    }

    private var displayModeHint: String {
        switch displayMode {
        case .original: "只显示原邮件"
        case .translated: "只显示译文，适合窗口较窄时阅读"
        case .bilingual: "左右并排对照，中间分隔线可拖拽调宽度"
        }
    }

    /// 按显示模式渲染。双语模式下两者之间的分隔线可拖拽调整**宽度**。
    @ViewBuilder
    private func previews(_ inspection: EmailInspection) -> some View {
        switch displayMode {
        case .original:
            originalPane(inspection)
                .padding(12)

        case .translated:
            translatedPane(inspection)
                .padding(12)

        case .bilingual:
            HSplitView {
                originalPane(inspection)
                translatedPane(inspection)
            }
            .padding(12)
        }
    }

    private func originalPane(_ inspection: EmailInspection) -> some View {
        PreviewPane(
            title: "原文",
            subtitle: "\(inspection.originalHTML.count) 字符",
            html: inspection.originalHTML,
            inlineResources: inspection.decoded.inlineResources,
            allowsRemoteContent: allowsRemoteContent,
            accent: .secondary
        )
    }

    private func translatedPane(_ inspection: EmailInspection) -> some View {
        PreviewPane(
            title: model.isShowingRealTranslation
                ? "译文 · \(TranslationLanguages.displayName(for: model.targetLanguage))"
                : "切片后",
            subtitle: "\(inspection.segments.count) 段",
            html: inspection.splicedHTML,
            inlineResources: inspection.decoded.inlineResources,
            allowsRemoteContent: allowsRemoteContent,
            accent: inspection.fidelity.nonTextBytesIdentical ? .green : .red,
            imageTranslation: imageTranslationPresentation(for: inspection)
        )
    }

    /// 图片翻译的呈现层：**每张可翻的图都应有角标** ——
    /// 未翻译 = 「译」（idle 的图不在状态字典里，必须先铺上默认角标），
    /// 翻译中 = 「…」，已翻译 = 「原」（点它切回原图），失败 = 「译」可重试。
    /// 内联图始终参与；外部图只在远程内容被放行时参与（拦截中的图连显示都没有）。
    private func imageTranslationPresentation(for inspection: EmailInspection) -> EmailWebView.ImageTranslationPresentation {
        var badges: [String: ImageTranslationOverlay.Badge] = [:]
        for (cid, resource) in inspection.decoded.inlineResources {
            let mime = resource.mimeType.lowercased()
            guard mime.hasPrefix("image/"), !mime.contains("gif") else { continue }
            badges[cid] = .translate
        }
        if allowsRemoteContent {
            for url in RemoteContentScanner.remoteImageURLs(in: inspection.splicedHTML) {
                badges[url] = .translate
            }
        }
        for (key, state) in model.imageTranslations {
            switch state {
            case .running: badges[key] = .busy
            case .translated: badges[key] = .restore
            case .failed: badges[key] = .translate
            }
        }
        return EmailWebView.ImageTranslationPresentation(
            badges: badges,
            results: model.translatedImageResults,
            onAction: { key in model.imageAction(for: key) }
        )
    }

    private func summaryBar(_ inspection: EmailInspection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 下面这一整块都是给开发者看的：保真指标、MIME 结构、字节数。
            // 正常使用只需要知道"这是哪封邮件"。
            if isDeveloperMode {
                developerSummary(inspection)
            }

            messageLine
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// 当前是哪封邮件。开发者模式下多带一个内容 ID（排障时对日志用）。
    @ViewBuilder
    private var messageLine: some View {
        if let message = model.currentMessage {
            Text(
                isDeveloperMode
                    ? "\(message.displayTitle)　·　\(message.from)　·　id \(message.id)"
                    : "\(message.displayTitle)　·　\(message.from)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
    }

    /// 开发者专属的指标区。
    @ViewBuilder
    private func developerSummary(_ inspection: EmailInspection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 窄窗口下 chip 会溢出，放进横向滚动容器里
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("原始 MIME \(model.sourceBytes) B", color: .blue)
                    chip("提取 \(inspection.segments.count) 段", color: .blue)
                    chip("改动 \(inspection.fidelity.changedSegmentCount) 段", color: .blue)
                    chip(
                        inspection.fidelity.nonTextBytesIdentical ? "非文本字节一致" : "非文本字节被改动",
                        color: inspection.fidelity.nonTextBytesIdentical ? .green : .red
                    )
                    chip(
                        inspection.fidelity.tagSequenceIdentical ? "标签序列一致" : "标签序列被改动",
                        color: inspection.fidelity.tagSequenceIdentical ? .green : .red
                    )
                    if inspection.usedPlainTextFallback {
                        chip("纯文本回退", color: .orange)
                    }

                    // 被标签切开的孤立虚词：无上下文引擎下会保留原文
                    let orphanCount = inspection.segments.filter(\.isContextlessOrphan).count
                    if orphanCount > 0 {
                        chip(orphanChipLabel(count: orphanCount), color: .orange)
                    }

                    // 缓存命中情况：重开同一封邮件应该直接命中，不该再跑一次翻译
                    if let cache = cacheChip {
                        chip(cache.label, color: cache.color)
                    }
                }
            }

            Text(inspection.fidelity.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !inspection.decoded.structureSummary.isEmpty {
                Text(inspection.decoded.structureSummary.joined(separator: "   |   "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    /// 缓存 chip 的文案与配色。未知状态不给 chip，免得空窗期闪一个假的结论。
    private var cacheChip: (label: String, color: Color)? {
        switch model.cacheStatus {
        case .unknown: nil
        case .hit: ("缓存命中", .green)
        case .missed: ("缓存未命中", .secondary)
        case .stored: ("已写入缓存", .blue)
        case .bypassed: ("已绕过缓存", .orange)
        }
    }

    /// 孤立片段那个 chip 的文案。
    ///
    /// 分两种情况是有意义的：Apple 这类看不到上下文的引擎会**跳过**它们
    /// （保留原文），而将来的 LLM 有上下文、会照常翻译。
    private func orphanChipLabel(count: Int) -> String {
        model.skipsContextlessOrphans
            ? "跳过 \(count) 段孤立片段"
            : "\(count) 段孤立片段（交给引擎翻）"
    }

    private func segmentsTable(_ inspection: EmailInspection) -> some View {
        Table(inspection.segments) {
            TableColumn("#") { segment in
                Text("\(segment.id)").monospacedDigit()
            }
            .width(36)

            TableColumn("类型") { segment in
                Text(segment.kind.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("上下文") { segment in
                Text(segment.ancestorTags.suffix(3).joined(separator: " › "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .width(140)

            TableColumn("原文") { segment in
                Text(segment.sourceText).lineLimit(2).textSelection(.enabled)
            }
        }
    }

    /// 底部的折叠条。整条都可点，不只是一个箭头 —— 点击区域大得多。
    private func segmentsToggleBar(count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isSegmentsVisible.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSegmentsVisible ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                Text("提取出的片段")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if isSegmentsVisible {
                    Text("（这些是送去翻译的文本，区间之外一个字节都不碰）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(isSegmentsVisible ? "点击隐藏" : "点击展开")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor))
        .help(isSegmentsVisible ? "隐藏片段列表，把空间让给预览" : "展开片段列表")
    }

    // MARK: - 小组件

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func placeholder(_ message: String, isError: Bool = false) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(isError ? .orange : .secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
