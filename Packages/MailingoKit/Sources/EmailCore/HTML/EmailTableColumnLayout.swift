import Foundation

/// Constrain fixed-width containers without stretching them; preserve explicit
/// column proportions in single-row layout tables. Newsletter items commonly use
/// separate nested tables; auto layout would size every item independently.
/// This only changes the rendering copy, never the cached or translated HTML.
enum EmailTableColumnLayout {
    private struct Table {
        let range: Range<String.Index>
        let width: Double?
        var rows = 0
        var cells: [(range: Range<String.Index>, width: Double?)] = []
        var keepsNativeColumns = false
    }

    // Consume comments and raw-text elements whole so markup inside them cannot
    // create fake tables. Quoted attribute values may themselves contain `>`.
    private static let tokens = try! NSRegularExpression(pattern:
        #"(?is)<!--.*?-->|<(script|style|textarea)\b[^>]*>.*?</\1\s*>|</?[a-z][a-z0-9]*\b(?:"[^"]*"|'[^']*'|[^'">])*>"#)
    private static let styleAttribute = try! NSRegularExpression(pattern:
        #"(?is)\sstyle\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    private static let cssWidth = try! NSRegularExpression(pattern:
        #"(?i)(?:^|;)\s*width\s*:\s*([^;]+)"#)
    private static let fixedLength = try! NSRegularExpression(pattern:
        #"(?i)^\s*([0-9]+(?:\.[0-9]+)?)\s*(px|pt)?\s*(?:!important\s*)?$"#)

    static func preservingColumnRatios(in html: String) -> String {
        var stack: [Table] = []
        var edits: [(Range<String.Index>, String)] = []
        for token in tokens.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(token.range, in: html) else { continue }
            let tag = String(html[range])
            let name = tag.dropFirst().prefix { $0.isLetter || $0 == "/" }.lowercased()
            switch name {
            case "table":
                let width = fixedWidth(in: tag)
                stack.append(Table(range: range, width: width))
                if let width {
                    // Keep the authored maximum instead of stretching logos,
                    // tickets and inner content tables to the entire viewport.
                    // No !important: the sender's responsive media queries win.
                    edits.append((range, addingStyle("width:min(100%,\(width)px);", to: tag)))
                }
            case "tr":
                if !stack.isEmpty { stack[stack.count - 1].rows += 1 }
            case "td", "th":
                guard !stack.isEmpty else { continue }
                let attributes = ReplyQuotePolicy.attributes(in: tag)
                if ["colspan", "rowspan"].contains(where: { attributes[$0] != nil && attributes[$0] != "1" })
                    || attributes["style"]?.contains("border-right") == true {
                    stack[stack.count - 1].keepsNativeColumns = true
                }
                stack[stack.count - 1].cells.append((range, fixedWidth(in: tag)))
            case "/table":
                guard let table = stack.popLast(), let width = table.width,
                      table.rows == 1, table.cells.count > 1, !table.keepsNativeColumns,
                      table.cells.allSatisfy({ $0.width != nil }) else { continue }
                let total = table.cells.reduce(0) { $0 + ($1.width ?? 0) }
                // Only explicit complete column grids: leave ambiguous tables,
                // spacers and multi-row data tables at their native column sizing.
                guard abs(total - width) <= max(2, width * 0.02) else { continue }
                if let existing = edits.firstIndex(where: { $0.0 == table.range }) { edits.remove(at: existing) }
                let layout = table.cells.count == 2 ? "fixed" : "auto"
                edits.append((table.range, addingStyle("width:min(100%,\(width)px);table-layout:\(layout);", to: String(html[table.range]))))
                for cell in table.cells {
                    let percentage = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), (cell.width ?? 0) / total * 100)
                    edits.append((cell.range, addingStyle("width:\(percentage)%;", to: String(html[cell.range]))))
                }
            default: break
            }
        }
        var result = html
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func fixedWidth(in tag: String) -> Double? {
        let attributes = ReplyQuotePolicy.attributes(in: tag)
        if let style = attributes["style"] {
            let declarations = cssWidth.matches(in: style, range: NSRange(style.startIndex..., in: style)).compactMap {
                Range($0.range(at: 1), in: style).map { String(style[$0]) }
            }
            // Respect CSS cascade order, including percentages following px and
            // important declarations preceding ordinary declarations.
            let value = declarations.last(where: { $0.contains("!important") }) ?? declarations.last
            if let value {
                guard let match = fixedLength.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                      let numberRange = Range(match.range(at: 1), in: value),
                      let number = Double(value[numberRange]), number.isFinite, number > 0 else { return nil }
                let unit = Range(match.range(at: 2), in: value).map { String(value[$0]) }
                return unit == "pt" ? number * 4 / 3 : number
            }
        }
        guard let raw = attributes["width"], let width = Double(raw), width.isFinite, width > 0 else { return nil }
        return width
    }

    private static func addingStyle(_ declarations: String, to tag: String) -> String {
        if let match = styleAttribute.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
           let range = Range(match.range, in: tag) {
            for group in 1...3 {
                if let value = Range(match.range(at: group), in: tag) {
                    var result = tag
                    // HTML-escape double quotes if the original used single quotes.
                    let style = String(tag[value]).replacingOccurrences(of: "\"", with: "&quot;")
                    result.replaceSubrange(range, with: " style=\"\(style);\(declarations)\"")
                    return result
                }
            }
        }
        var result = tag
        result.insert(contentsOf: " style=\"\(declarations)\"", at: result.index(before: result.endIndex))
        return result
    }
}
