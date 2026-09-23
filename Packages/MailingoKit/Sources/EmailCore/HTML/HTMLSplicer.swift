import Foundation

/// 把译文写回原始 HTML。
///
/// 这是整个保真方案的落点：**只替换 `coreRange`，其余字节一个都不碰。**
/// 不是"改完 DOM 再序列化"，而是"在原串上打补丁"—— 所以
/// `href` / `class` / `style` / `data-*` / 注释 / DOM 层级在物理上不可能被改动。
public enum HTMLSplicer {

    /// - Parameters:
    ///   - html: 原始 HTML（与生成 segments 时传入的必须是同一份）
    ///   - segments: 文档顺序的片段（`SegmentExtractor` 的产出天然有序）
    ///   - translations: `segment.id` → 译文。缺失的片段保持原文不动。
    /// - Returns: 切片后的 HTML
    public static func splice(
        html: String,
        segments: [TranslationSegment],
        translations: [Int: String]
    ) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var cursor = html.startIndex

        for segment in segments {
            // 防御：区间必须有序且不重叠，否则说明 segments 不是按文档序生成的
            guard segment.coreRange.lowerBound >= cursor else { continue }

            out += html[cursor..<segment.coreRange.lowerBound]

            if let translated = translations[segment.id], translated != segment.sourceText {
                // 译文必须重新转义：引擎返回的是纯文本，& < > 会破坏结构
                out += HTMLEntities.escapeText(translated)
            } else {
                // 没有译文，或译文与原文相同 → 写回**原始字节**。
                //
                // 这一步不只是省事：原文里 `&#233;`、`&nbsp;` 这类写法和它们的
                // 规范化形式（`é`、U+00A0）渲染结果一样，但字节不同。如果无脑走
                // escapeText，一趟"没改动任何东西"的切片也会改掉这些字节，
                // diff 变脏、保真断言也被削弱。写回原字节让"未翻译的片段
                // 逐字节不变"成为硬保证。
                out += html[segment.coreRange]
            }

            cursor = segment.coreRange.upperBound
        }

        out += html[cursor...]
        return out
    }

    /// 保真自检：切片前后，非文本部分的字节必须完全一致。
    ///
    /// 这是 `docs/IMPLEMENTATION_PLAN.md` §6 那条强断言的运行时版本 ——
    /// 它由"只替换区间"这个构造保证，但要真跑一遍才能确信没有被破坏。
    public static func verifyFidelity(
        original: String,
        spliced: String
    ) throws -> FidelityReport {
        // 每份 HTML **只分词一趟**，骨架和文本内容都从这一趟里出。
        //
        // 早先这里对每份 HTML 分了三趟（skeleton 内部一趟、直接又一趟，
        // 外加 tagSequence）—— 一封 287 KB 的邮件因此白烧了约 1.5 秒。
        // 现在每份一趟，开销直接减半。
        let originalRuns = try HTMLTokenizer.textRuns(in: original)
        let splicedRuns = try HTMLTokenizer.textRuns(in: spliced)

        let skeletonIdentical = HTMLTokenizer.skeleton(from: originalRuns, in: original)
            == HTMLTokenizer.skeleton(from: splicedRuns, in: spliced)

        let originalTags = try HTMLTokenizer.tagSequence(in: original)
        let splicedTags = try HTMLTokenizer.tagSequence(in: spliced)
        let tagsIdentical = originalTags == splicedTags

        let originalTexts = originalRuns.map { String(original[$0.range]) }
        let splicedTexts = splicedRuns.map { String(spliced[$0.range]) }
        let changed = zip(originalTexts, splicedTexts).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 { count += 1 }
        }

        var notes: [String] = []
        if !skeletonIdentical {
            notes.append("非文本字节发生变化（这是严重问题）")
        }
        if !tagsIdentical {
            notes.append("标签序列发生变化（这是严重问题）")
        }
        if originalTexts.count != splicedTexts.count {
            notes.append("文本节点数量变了：\(originalTexts.count) → \(splicedTexts.count)")
        }
        if notes.isEmpty {
            notes.append("非文本字节与标签序列均未变化，仅 \(changed) 个文本节点被替换")
        }

        return FidelityReport(
            nonTextBytesIdentical: skeletonIdentical,
            tagSequenceIdentical: tagsIdentical,
            changedSegmentCount: changed,
            detail: notes.joined(separator: "；")
        )
    }
}
