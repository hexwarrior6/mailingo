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

    @State private var isImporting = false
    @AppStorage("inspector.showSegments") private var isSegmentsVisible = true
    @AppStorage("inspector.displayMode") private var displayMode: DisplayMode = .bilingual
    /// 开发者模式：只影响「多显示哪些调试面板」，不影响布局代码本身。
    @AppStorage(DeveloperMode.storageKey) private var isDeveloperMode = false

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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                toolbarLeading
                if isDeveloperMode {
                    Divider().frame(height: 16)
                    toolbarTrailing
                }
                Spacer(minLength: 0)
            }
            .padding(12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { toolbarLeading; Spacer(minLength: 0) }
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
            Task { await model.loadMostRecent() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help(isDeveloperMode ? "重新读取已捕获的邮件列表" : "重新翻译")

        // 「打开 .eml」是调试用的（喂自造样本），正常使用不需要
        if isDeveloperMode {
            Button("打开 .eml…") { isImporting = true }
        }
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            accent: .secondary
        )
    }

    private func translatedPane(_ inspection: EmailInspection) -> some View {
        PreviewPane(
            title: model.isShowingRealTranslation ? "中文译文" : "切片后",
            subtitle: "\(inspection.segments.count) 段",
            html: inspection.splicedHTML,
            accent: inspection.fidelity.nonTextBytesIdentical ? .green : .red
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
