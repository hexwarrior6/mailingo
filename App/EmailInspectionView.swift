import EmailCore
import SwiftUI
import UniformTypeIdentifiers

/// M3 的验收界面：把「解析结果」直接摆出来。
///
/// 左边是原文渲染，右边是把每个文本节点换成标记后的渲染。
/// 两边一对比就能用眼睛确认方案 §6 的要求：
/// **表格还在、图片还在、颜色还在、条件注释还在，只有文字被换掉了。**
struct EmailInspectionView: View {

    @StateObject private var model = InspectorModel()
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            switch model.state {
            case .idle:
                placeholder("点「载入最近邮件」开始。")
            case .loading:
                placeholder("解析中…")
            case .failed(let message):
                placeholder(message, isError: true)
            case .loaded(let inspection):
                content(inspection)
            }
        }
        .onAppear {
            if case .idle = model.state {
                Task { await model.loadFromProbeLog() }
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
        HStack(spacing: 10) {
            Text("邮件解析").font(.headline)

            Button("载入最近邮件") {
                Task { await model.loadFromProbeLog() }
            }
            Button("打开 .eml…") { isImporting = true }

            Divider().frame(height: 16)

            Picker("翻译引擎", selection: $model.engineChoice) {
                ForEach(InspectorModel.EngineChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            Spacer()
        }
        .padding(12)
    }

    // MARK: - 主体

    private func content(_ inspection: EmailInspection) -> some View {
        VStack(spacing: 0) {
            summaryBar(inspection)
            Divider()

            HSplitView {
                PreviewPane(
                    title: "原文",
                    subtitle: "\(inspection.originalHTML.count) 字符",
                    html: inspection.originalHTML,
                    accent: .secondary
                )
                PreviewPane(
                    title: "切片后",
                    subtitle: "\(inspection.segments.count) 段被替换",
                    html: inspection.splicedHTML,
                    accent: inspection.fidelity.nonTextBytesIdentical ? .green : .red
                )
            }
            .padding(12)

            Divider()
            segmentsSection(inspection)
        }
    }

    private func summaryBar(_ inspection: EmailInspection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                chip("原始 MIME \(model.sourceBytes) B", color: .blue)
                chip("提取 \(inspection.segments.count) 段", color: .blue)
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
                Spacer()
                if let url = model.sourceURL {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.tertiary)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func segmentsSection(_ inspection: EmailInspection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("提取出的片段").font(.system(size: 12, weight: .semibold))
                Text("（这些就是会送去翻译的文本，区间之外一个字节都不碰）")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

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
                    Text(segment.sourceText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .frame(minHeight: 140)
        }
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
