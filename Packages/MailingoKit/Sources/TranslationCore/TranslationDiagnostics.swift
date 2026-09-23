import EmailCore
import Foundation
import Translation

/// 翻译链路自检。
///
/// 这不是调试残留，而是产品需要的能力：用户点「翻译」却什么都不发生时，
/// 我们必须能说清**为什么**（语言对不支持？语言包没下载？会话拿不到？），
/// 而不是给一个转圈或一句"失败了"。设置页/引导页将来直接用它。
///
/// 同时它也是 M4 的验收手段：把一份报告写下来，就能在不开 UI 的情况下
/// 确认 Apple Translation 真的通了。
public enum TranslationDiagnostics {

    public struct Sample: Sendable {
        public let source: String
        public let target: String
    }

    public struct Report: Sendable {
        public var targetLanguage: String
        public var availability: TranslationAvailability
        public var detectedSourceLanguage: String?
        public var segmentCount: Int
        public var translatedCount: Int
        public var changedCount: Int
        public var samples: [Sample]
        public var elapsedSeconds: TimeInterval
        public var failure: String?
        /// 常见目标语言的可用性，用于排查"到底哪个语言包装了"。
        public var languagePairs: [(language: String, availability: TranslationAvailability)]
        /// SwiftUI 桥接自检结果 —— 语言包没装时，这是唯一能验证桥接的方式。
        public var bridgeProbe: String?

        public var succeeded: Bool { failure == nil && availability.canTranslate }

        /// 人类可读的报告文本，直接写日志或贴进工单。
        public var text: String {
            var lines: [String] = []
            lines.append("翻译链路自检")
            lines.append("─────────────────────────────────────────")
            lines.append("目标语言        : \(targetLanguage)")
            lines.append("语言对可用性    : \(describe(availability))")
            lines.append("检测到的源语言  : \(detectedSourceLanguage ?? "（未能确定，交给引擎自动判断）")")
            if let bridgeProbe {
                lines.append("SwiftUI 桥接    : \(bridgeProbe)")
            }
            lines.append("片段数          : \(segmentCount)")
            lines.append("收到译文        : \(translatedCount)")
            lines.append("与原文不同      : \(changedCount)")
            lines.append(String(format: "耗时            : %.2f 秒", elapsedSeconds))

            if let failure {
                lines.append("")
                lines.append("❌ 失败：\(failure)")
            } else if changedCount == 0 {
                lines.append("")
                lines.append("⚠️ 没有任何片段发生变化 —— 要么原文已是目标语言，要么引擎没真正翻译。")
            } else {
                lines.append("")
                lines.append("✅ 翻译生效")
            }

            if !languagePairs.isEmpty {
                lines.append("")
                lines.append("常见目标语言的可用性")
                lines.append("─────────────────────────────────────────")
                for pair in languagePairs {
                    let mark = pair.availability == .installed ? "✅" : (pair.availability == .supported ? "⬇️ " : "❌")
                    lines.append("\(mark) \(pair.language)  \(describeShort(pair.availability))")
                }
            }

            if !samples.isEmpty {
                lines.append("")
                lines.append("抽样对照")
                lines.append("─────────────────────────────────────────")
                for (index, sample) in samples.enumerated() {
                    lines.append("[\(index + 1)] 原文: \(sample.source)")
                    lines.append("    译文: \(sample.target)")
                }
            }

            lines.append("")
            return lines.joined(separator: "\n")
        }

        private func describeShort(_ availability: TranslationAvailability) -> String {
            switch availability {
            case .installed: "已安装"
            case .supported: "需下载"
            case .unsupported: "不支持"
            }
        }

        private func describe(_ availability: TranslationAvailability) -> String {
            switch availability {
            case .installed: "已安装（可直接翻译，离线可用）"
            case .supported: "系统支持，但语言包未安装（首次翻译会触发系统下载）"
            case .unsupported: "不支持这个语言对"
            }
        }
    }

    /// 枚举一批常见目标语言的可用性。
    ///
    /// 排查"到底哪个语言包装了"时非常有用 —— 例如英语→中文没装、
    /// 但英语→日语装了，就能在不触发下载的前提下验证翻译链路本身是通的。
    public static func probeLanguagePairs(
        source: Locale.Language?,
        targets: [Locale.Language] = [
            TranslationLanguages.simplifiedChinese,
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "ja"),
            Locale.Language(identifier: "ko"),
            Locale.Language(identifier: "fr"),
            Locale.Language(identifier: "de"),
            Locale.Language(identifier: "es")
        ]
    ) async -> [(language: String, availability: TranslationAvailability)] {
        let system = LanguageAvailability()
        var result: [(String, TranslationAvailability)] = []

        for candidate in targets {
            let status: TranslationAvailability
            if let source {
                let raw = await system.status(from: source, to: candidate)
                status = switch raw {
                case .installed: .installed
                case .supported: .supported
                case .unsupported: .unsupported
                @unknown default: .unsupported
                }
            } else {
                let supported = await system.supportedLanguages
                let code = candidate.languageCode?.identifier
                status = supported.contains { $0.languageCode?.identifier == code } ? .supported : .unsupported
            }
            result.append((TranslationLanguages.displayName(for: candidate), status))
        }
        return result
    }

    /// 跑一遍：检测语言 → 问可用性 → 真翻几段 → 出报告。
    ///
    /// - Parameters:
    ///   - maxSamples: 最多真翻多少段。默认只翻前若干段，
    ///     避免自检本身变成一次全量翻译（那正是它要诊断的事情）。
    ///   - allowDownloadTrigger: 语言包未安装时是否允许继续尝试翻译。
    ///     传 `false` 时，遇到 `.supported`（支持但未下载）会**停在这里**并如实报告 ——
    ///     因为继续调用会弹出系统下载确认框。启动时的自动自检会传 false，
    ///     用户主动点「自检」时才传 true。
    public static func probe(
        segments: [TranslationSegment],
        target: Locale.Language = TranslationLanguages.simplifiedChinese,
        engine: TranslationEngine,
        maxSamples: Int = 6,
        allowDownloadTrigger: Bool = true
    ) async -> Report {
        let started = Date()
        let detected = LanguageDetector.detect(in: segments)

        var report = Report(
            targetLanguage: TranslationLanguages.displayName(for: target),
            availability: .unsupported,
            detectedSourceLanguage: detected.map { TranslationLanguages.displayName(for: $0) },
            segmentCount: segments.count,
            translatedCount: 0,
            changedCount: 0,
            samples: [],
            elapsedSeconds: 0,
            failure: nil,
            languagePairs: [],
            bridgeProbe: nil
        )

        report.availability = await engine.availability(source: detected, target: target)
        report.languagePairs = await probeLanguagePairs(source: detected)
        // 桥接自检放在最前面：语言包没装时它是唯一能验证 `.translationTask` 通路的手段
        if let apple = engine as? AppleTranslationEngine {
            // 连续取 3 次：只取到第一次说明配置没有真正"变化"（典型 bug 特征）
            let results = await apple.probeSessionRepeatedly(times: 3)
            let succeeded = results.filter(\.succeeded).count
            let detail = results.map(\.summary).joined(separator: "\n                 ")
            report.bridgeProbe = "连续请求 3 次，成功 \(succeeded) 次\n                 " + detail
        }

        guard report.availability.canTranslate else {
            report.failure = "语言对不可用：\(detected?.minimalIdentifier ?? "自动检测") → \(target.minimalIdentifier)"
            report.elapsedSeconds = Date().timeIntervalSince(started)
            return report
        }

        if report.availability == .supported, !allowDownloadTrigger {
            report.failure = "语言包尚未安装（未触发系统下载，避免突然弹窗）。点「翻译自检」可主动触发。"
            report.elapsedSeconds = Date().timeIntervalSince(started)
            return report
        }

        guard !segments.isEmpty else {
            report.failure = "没有可翻译的片段（邮件可能是空的，或全文都是数字/URL）"
            report.elapsedSeconds = Date().timeIntervalSince(started)
            return report
        }

        let probeSegments = Array(segments.prefix(maxSamples))

        do {
            let translated = try await engine.translate(
                segments: probeSegments,
                sourceLanguage: detected,
                targetLanguage: target
            )
            report.translatedCount = translated.count

            let byId = Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0.targetText) })
            report.changedCount = probeSegments.reduce(into: 0) { count, segment in
                if let text = byId[segment.id], text != segment.sourceText { count += 1 }
            }
            report.samples = probeSegments.compactMap { segment in
                guard let text = byId[segment.id] else { return nil }
                return Sample(source: segment.sourceText, target: text)
            }
        } catch {
            report.failure = String(describing: error)
        }

        report.elapsedSeconds = Date().timeIntervalSince(started)
        return report
    }
}
