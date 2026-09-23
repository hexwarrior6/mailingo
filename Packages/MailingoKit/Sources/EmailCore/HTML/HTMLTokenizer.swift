import Foundation

/// 单遍 HTML tokenizer。
///
/// ## 为什么不用 DOM
///
/// 方案 §4.4 的核心决定：**不把 HTML 解析成 DOM 再序列化回去**。
/// 任何序列化器都会重排属性顺序、补全/删除标签、改写实体、规范化空白 ——
/// 保真度必然受损，而邮件 HTML 恰恰是"靠畸形标签和表格撑起排版"的重灾区。
///
/// 所以这里只做一件事：**给每个文本节点标出它在原始字符串里的精确区间**。
/// 之后只替换这些区间，其余字节一个都不碰。
///
/// 同时维护一个开放标签栈，用来给每个文本节点附上上下文（heading / link / tableCell…），
/// 这些信息将来喂给 LLM 能提高语气和术语的准确性。
struct HTMLTokenizer {

    /// 一个文本节点。
    struct TextRun {
        /// 在原始 HTML 中的完整区间（含前后空白）。
        let range: Range<String.Index>
        /// 祖先标签名，由内到外。
        let ancestorTags: [String]
    }

    /// 自闭合 / 空元素：不入栈。
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// 内容不能当普通文本处理的元素。
    /// `script` / `style` 不是给人看的；`title` 对邮件正文无意义（方案 §4.4 默认跳过）；
    /// `textarea` 内容里的 `<` 也不该被当标签。这些元素的内容整体跳过。
    private static let skippedContentElements: Set<String> = [
        "script", "style", "title", "textarea"
    ]

    /// 取出所有文本节点。
    static func textRuns(in html: String) -> [TextRun] {
        var runs: [TextRun] = []
        var stack: [String] = []
        var i = html.startIndex

        while i < html.endIndex {
            let ch = html[i]

            guard ch == "<" else {
                // ── 文本节点：一路走到下一个 '<'
                var j = i
                while j < html.endIndex, html[j] != "<" {
                    j = html.index(after: j)
                }
                runs.append(TextRun(range: i..<j, ancestorTags: stack))
                i = j
                continue
            }

            // ── 注释：整段跳过
            if html[i...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: i..<html.endIndex) {
                    i = end.upperBound
                } else {
                    i = html.endIndex
                }
                continue
            }

            // ── DOCTYPE / 处理指令 / CDATA：跳到 '>'
            if html[i...].hasPrefix("<!") || html[i...].hasPrefix("<?") {
                if let gt = html[i...].firstIndex(of: ">") {
                    i = html.index(after: gt)
                } else {
                    i = html.endIndex
                }
                continue
            }

            // ── 标签
            guard let gt = html[i...].firstIndex(of: ">") else {
                // 落单的 '<' 没有闭合：当普通文本处理，别把后面的内容整段吃掉
                runs.append(TextRun(range: i..<html.endIndex, ancestorTags: stack))
                break
            }

            let inner = html[html.index(after: i)..<gt]   // 不含 '<' 和 '>'
            let isClosing = inner.hasPrefix("/")

            if isClosing {
                let name = tagName(from: inner.dropFirst())
                // 宽松闭合：往下找最近的同名标签，把它及其内层一起弹出。
                // 真实邮件里标签经常不配对，严格的栈会越走越歪。
                if let idx = stack.lastIndex(of: name) {
                    stack.removeSubrange(idx...)
                }
            } else {
                let isSelfClosing = inner.hasSuffix("/")
                let name = tagName(from: isSelfClosing ? inner.dropLast() : inner)

                if !isSelfClosing, !voidElements.contains(name), !name.isEmpty {
                    stack.append(name)

                    if skippedContentElements.contains(name) {
                        // 内容整体跳过，但要先把这一段"消化"掉，
                        // 否则里面的 '<' 会被误判成标签。
                        let afterOpen = html.index(after: gt)
                        if let closeRange = findClosingTag(name, in: html, from: afterOpen) {
                            // 弹出刚压入的这个标签
                            if stack.last == name { stack.removeLast() }
                            i = closeRange
                            continue
                        } else {
                            // 没有闭合标签：保守起见不消费内容，按普通标签继续
                            if stack.last == name { stack.removeLast() }
                        }
                    }
                }
            }

            i = html.index(after: gt)
        }

        return runs
    }

    /// 骨架：把所有文本节点替换成同一个占位符，其余字节原样保留。
    ///
    /// 用来做保真自检 —— 切片前后骨架必须完全一致，等价于
    /// 「非文本字节 100% 未变」这条 §6 的强断言。
    static func skeleton(of html: String, placeholder: Character = "\u{FFFC}") -> String {
        var out = ""
        var cursor = html.startIndex
        for run in textRuns(in: html) {
            out += html[cursor..<run.range.lowerBound]
            out.append(placeholder)
            cursor = run.range.upperBound
        }
        out += html[cursor...]
        return out
    }

    /// 标签序列（含属性原文），用于断言结构未变。
    static func tagSequence(in html: String) -> [String] {
        var tags: [String] = []
        var i = html.startIndex

        while i < html.endIndex {
            guard let lt = html[i...].firstIndex(of: "<") else { break }

            if html[lt...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: lt..<html.endIndex) {
                    tags.append(String(html[lt..<end.upperBound]))
                    i = end.upperBound
                } else { break }
                continue
            }

            guard let gt = html[lt...].firstIndex(of: ">") else { break }
            tags.append(String(html[lt...gt]))
            i = html.index(after: gt)
        }
        return tags
    }

    // MARK: - 辅助

    /// 从 `<div class="x">` 的 `div class="x"` 里取 `div`，统一小写。
    private static func tagName(from body: Substring) -> String {
        var name = ""
        for ch in body {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ":" {
                name.append(ch)
            } else {
                break
            }
        }
        return name.lowercased()
    }

    /// 找到 `</name ...>` 结束后的位置（大小写不敏感）。
    private static func findClosingTag(
        _ name: String,
        in html: String,
        from start: String.Index
    ) -> String.Index? {
        var searchStart = start
        let needle = "</" + name
        while searchStart < html.endIndex {
            guard let found = html.range(of: needle, options: .caseInsensitive, range: searchStart..<html.endIndex) else {
                return nil
            }
            // 确认边界，避免把 `</scriptfoo>` 当成 `</script>`
            let after = found.upperBound
            if after == html.endIndex || !(html[after].isLetter || html[after].isNumber) {
                guard let gt = html[after...].firstIndex(of: ">") else { return nil }
                return html.index(after: gt)
            }
            searchStart = found.upperBound
        }
        return nil
    }
}
