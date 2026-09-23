import Foundation

/// 从 HTML 里挑出"值得翻译"的文本节点。
///
/// 产出的是**区间**而不是字符串副本 —— 区间指向原始 HTML，切片阶段直接用它替换。
enum SegmentExtractor {

    /// 这些内容的翻译没有意义，或者翻译了反而有害。
    private static let maxSegmentLength = 4000

    static func extract(from html: String) -> [TranslationSegment] {
        var segments: [TranslationSegment] = []

        for run in HTMLTokenizer.textRuns(in: html) {
            let raw = html[run.range]

            // ── 去掉前后空白：空白必须留在原位，不能交给翻译引擎
            //    （引擎会把它们吃掉，导致 `word</b> <i>word` 之间的空格消失）
            guard let firstNonWS = raw.firstIndex(where: { !$0.isWhitespace }) else { continue }
            guard let lastNonWS = raw.lastIndex(where: { !$0.isWhitespace }) else { continue }
            let coreRange = firstNonWS..<raw.index(after: lastNonWS)

            // 把原文区间换算回整份 HTML 的坐标
            let absoluteCoreRange = coreRange.lowerBound..<coreRange.upperBound

            let decoded = HTMLEntities.decode(String(raw[coreRange])).trimmingCharacters(in: .whitespacesAndNewlines)

            guard shouldTranslate(decoded) else { continue }

            segments.append(
                TranslationSegment(
                    id: segments.count,
                    kind: SegmentKind.infer(from: run.ancestorTags),
                    sourceText: decoded,
                    range: run.range,
                    coreRange: absoluteCoreRange,
                    ancestorTags: run.ancestorTags
                )
            )
        }

        return segments
    }

    /// 过滤掉"没有翻译价值"的片段。
    ///
    /// 宁可少翻几个（比如纯数字的表格单元格），也不要把 URL、跟踪参数、
    /// 纯符号送进翻译引擎 —— 那既浪费额度，又会把不该改的东西改坏。
    private static func shouldTranslate(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.count <= maxSegmentLength else { return false }

        // 至少要有一个字母（涵盖 CJK，因为 CJK 字符 isLetter 为 true）。
        // 这样纯数字、纯符号、纯空白都会被跳过。
        guard text.contains(where: { $0.isLetter }) else { return false }

        // 纯 URL 不翻
        let lower = text.lowercased()
        let looksLikeURL = (lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www."))
            && !text.contains(where: { $0.isWhitespace })
        if looksLikeURL { return false }

        // 裸邮箱地址不翻（不含空白的单独一个 a@b.c）
        if !text.contains(where: { $0.isWhitespace }),
           text.filter({ $0 == "@" }).count == 1,
           text.contains(".") {
            return false
        }

        return true
    }
}
