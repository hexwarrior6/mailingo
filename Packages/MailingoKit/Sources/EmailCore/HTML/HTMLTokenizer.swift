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
        /// 最近的**块级**祖先元素（`p` / `td` / `li` / `div` …）。
        ///
        /// 判断两个文本节点是不是"同一个段落里被行内标签切开的兄弟"。
        /// 这个信息同时也是将来喂给 LLM 做上下文分组的依据。
        let blockAncestor: BlockContext?
    }

    /// 一个块级容器的**身份**。
    ///
    /// 必须带 `elementID` 而不是只比标签名：`<p>to</p><p>to</p>` 里两个 `p`
    /// 名字相同却是**不同的**段落，各自的 `to` 都是完整语境，不能算兄弟。
    /// elementID 用该标签在原文里的起始偏移，天然唯一。
    struct BlockContext: Equatable {
        let tag: String
        let elementID: Int
    }

    /// 标签栈里的一项。
    private struct OpenElement {
        let name: String
        let id: Int
    }

    /// 自闭合 / 空元素：不入栈。
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// 块级元素：它们划分"文本块"。
    ///
    /// 判断依据是"这个标签会不会开启一个新的文本容器"。
    /// 注意 `table` / `tr` 也算了进去 —— 单元格文字所在的是 `td`，
    /// 而 `td` 本来就在里面，所以取"最内层"的那个就能拿到 `td`。
    private static let blockLevelElements: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "center",
        "dd", "details", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "li",
        "main", "nav", "ol", "p", "pre", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "tr", "ul"
    ]

    /// 内容不能当普通文本处理的元素。
    /// `script` / `style` 不是给人看的；`title` 对邮件正文无意义（方案 §4.4 默认跳过）；
    /// `textarea` 内容里的 `<` 也不该被当标签。这些元素的内容整体跳过。
    private static let skippedContentElements: Set<String> = [
        "script", "style", "title", "textarea"
    ]

    /// 取出所有文本节点。
    ///
    /// 可以取消：这是一趟 O(n) 扫描，一封 287 KB 的 HTML 要 ~380 ms。
    /// 调用方（App 在快速切邮件时）会在结果不再需要时取消它，
    /// 所以这里每隔一段就查一次，让旧的活能提前停。
    static func textRuns(in html: String) throws -> [TextRun] {
        var runs: [TextRun] = []
        var stack: [OpenElement] = []
        var i = html.startIndex

        while i < html.endIndex {
            try Task.checkCancellation()
            let ch = html[i]

            guard ch == "<" else {
                // ── 文本节点：一路走到下一个 '<'
                //
                // 单个文本节点可能很长（一封信的正文就是一整段），所以这里也
                // 要查取消 —— 光靠外层的"每个 token 查一次"在一段超长文本里
                // 会漏掉。按字符数计数，而不是每字符都查（那会把扫描拖慢）。
                var j = i
                var scanned = 0
                while j < html.endIndex, html[j] != "<" {
                    j = html.index(after: j)
                    scanned += 1
                    if scanned >= 8192 {
                        try Task.checkCancellation()
                        scanned = 0
                    }
                }
                runs.append(TextRun(
                    range: i..<j,
                    ancestorTags: stack.map(\.name),
                    blockAncestor: stack.last { blockLevelElements.contains($0.name) }
                        .map { BlockContext(tag: $0.name, elementID: $0.id) }
                ))
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
                runs.append(TextRun(
                    range: i..<html.endIndex,
                    ancestorTags: stack.map(\.name),
                    blockAncestor: stack.last { blockLevelElements.contains($0.name) }
                        .map { BlockContext(tag: $0.name, elementID: $0.id) }
                ))
                break
            }

            let inner = html[html.index(after: i)..<gt]   // 不含 '<' 和 '>'
            let isClosing = inner.hasPrefix("/")

            if isClosing {
                let name = tagName(from: inner.dropFirst())
                // 宽松闭合：往下找最近的同名标签，把它及其内层一起弹出。
                // 真实邮件里标签经常不配对，严格的栈会越走越歪。
                if let idx = stack.lastIndex(where: { $0.name == name }) {
                    stack.removeSubrange(idx...)
                }
            } else {
                let isSelfClosing = inner.hasSuffix("/")
                let name = tagName(from: isSelfClosing ? inner.dropLast() : inner)

                if !isSelfClosing, !voidElements.contains(name), !name.isEmpty {
                    // 用 '<' 的偏移作为这个元素的唯一身份
                    stack.append(OpenElement(name: name, id: html.distance(from: html.startIndex, to: i)))

                    if skippedContentElements.contains(name) {
                        // 内容整体跳过，但要先把这一段"消化"掉，
                        // 否则里面的 '<' 会被误判成标签。
                        let afterOpen = html.index(after: gt)
                        if let closeRange = findClosingTag(name, in: html, from: afterOpen) {
                            // 弹出刚压入的这个标签
                            if stack.last?.name == name { stack.removeLast() }
                            i = closeRange
                            continue
                        } else {
                            // 没有闭合标签：保守起见不消费内容，按普通标签继续
                            if stack.last?.name == name { stack.removeLast() }
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
    static func skeleton(of html: String, placeholder: Character = "\u{FFFC}") throws -> String {
        try skeleton(from: try textRuns(in: html), in: html, placeholder: placeholder)
    }

    /// 从**已经算好的**文本节点拼骨架。
    ///
    /// 存在的意义就是省掉重复分词：保真自检既要骨架、又要文本内容，
    /// 两者来自同一趟 `textRuns`。早先 `skeleton(of:)` 内部自己再跑一趟，
    /// 于是一封 287 KB 的邮件白烧了 380 ms —— 实测那一趟占了整个
    /// `apply` 的四分之一。
    ///
    /// 传进来的 `runs` 必须来自同一份 `html`，否则拼出来的骨架没有意义。
    static func skeleton(
        from runs: [TextRun],
        in html: String,
        placeholder: Character = "\u{FFFC}"
    ) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var cursor = html.startIndex
        for run in runs {
            out += html[cursor..<run.range.lowerBound]
            out.append(placeholder)
            cursor = run.range.upperBound
        }
        out += html[cursor...]
        return out
    }

    /// 标签序列（含属性原文），用于断言结构未变。
    static func tagSequence(in html: String) throws -> [String] {
        var tags: [String] = []
        var i = html.startIndex

        while i < html.endIndex {
            try Task.checkCancellation()
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
