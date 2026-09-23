import EmailCore
import Foundation
import SwiftUI

/// 邮件解析看板的状态与加载逻辑。
@MainActor
final class InspectorModel: ObservableObject {

    enum EngineChoice: String, CaseIterable, Identifiable {
        case marker
        case identity

        var id: String { rawValue }

        var label: String {
            switch self {
            case .marker: "标记替换（看保真）"
            case .identity: "原样返回（看零改动）"
            }
        }

        var engine: TranslationEngine {
            switch self {
            case .marker: MarkerTranslationEngine()
            case .identity: IdentityTranslationEngine()
            }
        }
    }

    enum LoadState {
        case idle
        case loading
        case failed(String)
        case loaded(EmailInspection)
    }

    @Published private(set) var state: LoadState = .idle
    @Published var engineChoice: EngineChoice = .marker {
        didSet { recompute() }
    }

    /// 保留最近一次解析结果，切换引擎时不必重新解码。
    private var analysis: EmailAnalysis?
    private(set) var sourceURL: URL?
    private(set) var sourceBytes: Int = 0

    /// 从 appex 的沙盒容器里读最近一封真实邮件。
    func loadFromProbeLog() async {
        let url = ProbeLog.lastMessageURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            state = .failed("还没拿到邮件。\n\n请确认 Mail 里的 Mailingo 扩展已启用，并打开几封邮件 —— appex 会把最近一封的原始 MIME 写到这里：\n\(url.path)")
            return
        }

        state = .loading
        do {
            let data = try Data(contentsOf: url)
            try await analyze(data: data, sourceURL: url)
        } catch {
            state = .failed("读取失败：\(error.localizedDescription)")
        }
    }

    /// 从用户选的文件读（用于喂自造的 fixture）。
    func load(fileURL: URL) async {
        state = .loading
        do {
            let data = try Data(contentsOf: fileURL)
            try await analyze(data: data, sourceURL: fileURL)
        } catch {
            state = .failed("读取失败：\(error.localizedDescription)")
        }
    }

    func recompute() {
        guard let analysis else { return }
        state = .loaded(EmailInspector.apply(translations: Self.translations(for: analysis, engine: engineChoice), to: analysis))
    }

    // MARK: - 内部

    private func analyze(data: Data, sourceURL: URL?) async throws {
        // 解析放到后台：营销邮件动辄几百 KB，别卡住 UI
        let analysis = try await Task.detached(priority: .userInitiated) {
            try EmailInspector.analyze(rawMessage: data)
        }.value

        self.analysis = analysis
        self.sourceURL = sourceURL
        self.sourceBytes = data.count
        state = .loaded(EmailInspector.apply(translations: Self.translations(for: analysis, engine: engineChoice), to: analysis))
    }

    private static func translations(for analysis: EmailAnalysis, engine: EngineChoice) -> [Int: String] {
        switch engine {
        case .marker:
            Dictionary(uniqueKeysWithValues: analysis.segments.map { ($0.id, "〖\($0.id)〗") })
        case .identity:
            Dictionary(uniqueKeysWithValues: analysis.segments.map { ($0.id, $0.sourceText) })
        }
    }
}
