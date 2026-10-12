import Foundation

/// Excludes quoted history before language detection or any translation engine sees it.
/// Original HTML and quote bytes remain untouched for the fidelity pipeline.
enum ReplyQuotePolicy {
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
    )
    private static let attributionPattern = try! NSRegularExpression(
        pattern: #"(?i)^On\s+.+(?:wrote|sent):\s*$"#
    )

    static func attributes(in tag: String) -> [String: String] {
        var values: [String: String] = [:]
        for match in attributePattern.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let keyRange = Range(match.range(at: 1), in: tag) else { continue }
            for group in 2...4 {
                if let valueRange = Range(match.range(at: group), in: tag) {
                    values[String(tag[keyRange]).lowercased()] = String(tag[valueRange]).lowercased()
                    break
                }
            }
        }
        return values
    }

    static func isQuoteContainer(name: String, attributes: [String: String]) -> Bool {
        if name == "blockquote", attributes["type"] == "cite" { return true }
        let classes = Set((attributes["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
        return !classes.isDisjoint(with: ["gmail_quote", "gmail_quote_container", "yahoo_quoted", "protonmail_quote", "moz-cite-prefix"])
    }

    /// Outlook puts its header and old body in sibling containers, so the marker
    /// starts a quoted tail rather than just excluding the header element.
    static func startsQuotedTail(_ attributes: [String: String]) -> Bool {
        ["divrplyfwdmsg", "appendonsend"].contains(attributes["id"] ?? "")
    }

    static func currentMessageRuns(in html: String) throws -> [HTMLTokenizer.TextRun] {
        let runs = try HTMLTokenizer.textRuns(in: html)
        let hasStructuredQuote = runs.contains { $0.isReplyQuote }
        var result: [HTMLTokenizer.TextRun] = []
        var quotedTail = false
        for run in runs {
            try Task.checkCancellation()
            guard !run.isReplyQuote, !quotedTail else { continue }
            let lines = html[run.range].components(separatedBy: "\n").map {
                HTMLEntities.decode($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !lines.contains(where: { $0.hasPrefix(">") || isAttribution($0) }) {
                result.append(run)
                continue
            }
            // Plain-text fallback and <pre> replies may put current and quoted
            // lines in one text node. Keep source ranges so splicing stays exact.
            var cursor = run.range.lowerBound
            while cursor < run.range.upperBound {
                let end = html[cursor..<run.range.upperBound].firstIndex(of: "\n") ?? run.range.upperBound
                let range = cursor..<end
                let text = HTMLEntities.decode(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
                if isAttribution(text) {
                    // With structural quotes, only skip attribution: a reply
                    // after the closed quote still belongs to the current sender.
                    if !hasStructuredQuote { quotedTail = true }
                } else if !text.hasPrefix(">"), !quotedTail {
                    result.append(.init(range: range, ancestorTags: run.ancestorTags,
                                        blockAncestor: run.blockAncestor, isReplyQuote: false))
                }
                if end == run.range.upperBound { break }
                cursor = html.index(after: end)
            }
        }
        return result
    }

    static func isAttribution(_ text: String) -> Bool {
        attributionPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            || text.range(of: #"^-{2,}\s*(?:Original Message|原始邮件|原始郵件)\s*-{2,}$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }
}
