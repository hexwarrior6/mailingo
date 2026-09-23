import Foundation

/// 从 HTML 里挑出"值得翻译"的文本节点。
///
/// 产出的是**区间**而不是字符串副本 —— 区间指向原始 HTML，切片阶段直接用它替换。
enum SegmentExtractor {

    /// 单个片段的最大长度。超长的多半是 base64 数据或畸形内容。
    private static let maxSegmentLength = 4000

    /// 孤立虚词清单。
    ///
    /// 这些词的共同点是：**脱离语境就没有确定的译法**。
    /// 当它们被行内标签从句子中间切开时（`<b>9:00</b> to <b>11:00</b>` 里的 `to`），
    /// 无上下文的引擎（Apple 翻译）翻出来往往是错的 —— 翻错比不翻更糟，
    /// 所以这类片段整段保留原文，交给有上下文的引擎（LLM）去处理。
    ///
    /// 只收**虚词**，不收实义词：`save` / `next` / `no` 这些即使很短也可能是
    /// 按钮文字，必须照常翻译（它们通常独占一个块，见 `isFragment` 的判断）。
    private static let orphanTokens: Set<String> = [
        // 介词
        "to", "at", "of", "in", "on", "for", "by", "with", "from", "into", "onto",
        "upon", "about", "above", "below", "over", "under", "between", "among",
        "during", "before", "after", "since", "until", "till", "per", "via", "vs",
        "through", "within", "without", "against", "toward", "towards", "across",
        // 冠词 / 限定词
        "the", "a", "an", "this", "that", "these", "those", "some", "any", "each",
        "every", "both", "either", "neither", "such", "same", "other", "another",
        // 连词
        "and", "or", "nor", "but", "so", "if", "then", "than", "because", "while",
        "when", "where", "whether", "though", "although", "unless", "yet",
        // 代词
        "it", "its", "he", "she", "they", "them", "their", "his", "her", "our",
        "your", "my", "we", "you", "us", "who", "whom", "whose", "which", "what",
        // 助动词 / 系动词
        "is", "are", "was", "were", "be", "been", "being", "am", "has", "have",
        "had", "do", "does", "did", "will", "would", "shall", "should", "can",
        "could", "may", "might", "must",
        // 否定 / 副词性小品词
        "not", "no", "as", "also", "only", "just", "even", "still", "too", "very",
        "up", "out", "off", "down", "back", "away", "here", "there",
        // 序数后缀（`14<sup>th</sup>` 这类）
        "st", "nd", "rd", "th",
        // 常见缩写
        "etc", "eg", "ie", "aka", "vs"
    ]

    static func extract(from html: String) -> [TranslationSegment] {
        let runs = HTMLTokenizer.textRuns(in: html)
        var segments: [TranslationSegment] = []

        for (index, run) in runs.enumerated() {
            let raw = html[run.range]

            // ── 去掉前后空白：空白必须留在原位，不能交给翻译引擎
            //    （引擎会把它们吃掉，导致 `word</b> <i>word` 之间的空格消失）
            guard let firstNonWS = raw.firstIndex(where: { !$0.isWhitespace }),
                  let lastNonWS = raw.lastIndex(where: { !$0.isWhitespace }) else { continue }
            let coreRange = firstNonWS..<raw.index(after: lastNonWS)

            let decoded = HTMLEntities.decode(String(raw[coreRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard shouldTranslate(decoded) else { continue }

            // 注意这里用的是**全部文本节点**（runs）而不是已过滤的片段：
            // ` to ` 的邻居 `9:00` 是纯数字、本身不会成为片段，
            // 但它恰恰是判断"我在句子中间"的关键证据。
            let isOrphan = isFragment(runs: runs, at: index) && isOrphanToken(decoded)

            segments.append(
                TranslationSegment(
                    id: segments.count,
                    kind: SegmentKind.infer(from: run.ancestorTags),
                    sourceText: decoded,
                    range: run.range,
                    coreRange: coreRange,
                    ancestorTags: run.ancestorTags,
                    blockAncestor: run.blockAncestor?.tag,
                    isContextlessOrphan: isOrphan
                )
            )
        }

        return segments
    }

    // MARK: - 孤立片段判定

    /// 这个文本节点是不是"被行内标签从一段话里切出来的"。
    ///
    /// 判据：同一个**块级容器**里还有紧邻的文本节点。
    /// 独占一个块（例如 `<button>No</button>`）的文本不算片段 ——
    /// 那种短词是有完整语境的（它自己就是一句话）。
    private static func isFragment(runs: [HTMLTokenizer.TextRun], at index: Int) -> Bool {
        // 比的是**元素身份**（含 elementID），不是标签名 ——
        // `<p>to</p><p>to</p>` 里两个 p 名字相同但是不同段落，不能算兄弟。
        guard let block = runs[index].blockAncestor else { return false }
        if index > 0, runs[index - 1].blockAncestor == block { return true }
        if index + 1 < runs.count, runs[index + 1].blockAncestor == block { return true }
        return false
    }

    /// 是不是清单里的虚词。
    ///
    /// 限制为纯 ASCII 字母：中文不存在"虚词被标签切开"这种问题，
    /// 而 CJK 短词（"的"、"和"）单独翻也是对的。
    private static func isOrphanToken(_ text: String) -> Bool {
        let normalized = text.lowercased()
        guard !normalized.isEmpty, normalized.count <= 10 else { return false }
        guard normalized.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return orphanTokens.contains(normalized)
    }

    // MARK: - 基本过滤

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
