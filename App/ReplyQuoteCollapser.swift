import Foundation

/// Trusted rendering code, evaluated by the app while email-authored scripts remain disabled.
/// Uses native <details>: mouse and keyboard toggling require no email JavaScript.
enum ReplyQuoteCollapser {
    static let expandedStateScript = #"Array.from(document.querySelectorAll('details[data-mailingo-quote][open]'), d => d.dataset.mailingoQuote)"#

    static func script(expandedIDs: [String] = []) -> String {
        let json = String(data: try! JSONSerialization.data(withJSONObject: expandedIDs), encoding: .utf8)!
        return "(" + implementation + ")(" + json + ")"
    }

    private static let implementation = #"""
    (expandedIDs) => {
        const body = document.body;
        if (!body) return 0;
        if (body.querySelector('details[data-mailingo-quote]')) return body.querySelectorAll('details[data-mailingo-quote]').length;
        const quoteSelector = 'blockquote[type="cite" i], .gmail_quote, .gmail_quote_container, .yahoo_quoted, .protonmail_quote, .moz-cite-prefix';
        const tailSelector = '[id="divRplyFwdMsg" i], [id="appendonsend" i]';
        const attribution = text => /^On\s+.+(?:wrote|sent):\s*$/i.test(text.trim()) || /^-{2,}\s*(?:Original Message|原始邮件|原始郵件)\s*-{2,}$/i.test(text.trim());
        const opened = new Set(expandedIDs);
        let nextID = 0;
        const style = document.createElement('style');
        style.textContent = `
        details[data-mailingo-quote] { display:block!important; margin:6px 0!important; padding:0!important; border:0!important; background:transparent!important; box-shadow:none!important; }
        details[data-mailingo-quote] > summary { display:inline-block!important; width:auto!important; list-style:none!important; cursor:pointer!important; color:#888!important; font:normal 12px/1.5 -apple-system,BlinkMacSystemFont,sans-serif!important; padding:0!important; border:0!important; border-radius:0!important; background:transparent!important; box-shadow:none!important; text-align:left!important; text-decoration:underline!important; text-underline-offset:2px!important; }
        details[data-mailingo-quote] > summary::-webkit-details-marker { display:none!important; }
        details[data-mailingo-quote] > summary::marker { content:""; }
        details[data-mailingo-quote] > summary:hover { color:#666!important; }
        details[data-mailingo-quote][open] > summary { margin-bottom:6px!important; }
        details[data-mailingo-quote] > summary:focus-visible { outline:2px solid #007aff!important; outline-offset:2px!important; }
        details[data-mailingo-quote] > summary .mailingo-quote-open { display:none!important; }
        details[data-mailingo-quote][open] > summary .mailingo-quote-open { display:inline!important; }
        details[data-mailingo-quote][open] > summary .mailingo-quote-closed { display:none!important; }
        `;
        (document.head || body).appendChild(style);
        function fold(range) {
            const content = range.extractContents();
            const details = document.createElement('details');
            const id = String(nextID++);
            details.dataset.mailingoQuote = id;
            details.open = opened.has(id);
            const summary = document.createElement('summary');
            const closed = document.createElement('span');
            closed.className = 'mailingo-quote-closed';
            closed.textContent = '展开历史引用';
            const open = document.createElement('span');
            open.className = 'mailingo-quote-open';
            open.textContent = '收起历史引用';
            summary.append(closed, open);
            details.append(summary, content);
            range.insertNode(details);
        }
        function previousContent(node) {
            let previous = node.previousSibling;
            while (previous && previous.nodeType === Node.TEXT_NODE && !previous.textContent.trim()) previous = previous.previousSibling;
            return previous;
        }
        // Fold outer containers only: nested history becomes one disclosure.
        const containers = Array.from(body.querySelectorAll(quoteSelector)).filter(node => !node.parentElement?.closest(quoteSelector));
        for (const node of containers) {
            if (!node.isConnected || node.closest('details[data-mailingo-quote]')) continue;
            let start = node;
            let end = node;
            // Plain fallback marks quote lines with spans separated by <br>.
            // Combine adjacent quote lines, while leaving inline replies visible.
            if (node.tagName === 'SPAN') {
                let cursor = node.nextSibling;
                while (cursor) {
                    if ((cursor.nodeType === Node.TEXT_NODE && !cursor.textContent.trim()) || cursor.nodeName === 'BR') {
                        // Keep traversing whitespace and line breaks between quote lines.
                    } else if (cursor.nodeType === Node.ELEMENT_NODE && cursor.matches(quoteSelector)) {
                        end = cursor;
                    } else break;
                    cursor = cursor.nextSibling;
                }
            }
            const previous = previousContent(node);
            if (previous && attribution(previous.textContent)) start = previous;
            const range = document.createRange();
            range.setStartBefore(start);
            range.setEndAfter(end);
            fold(range);
        }
        // Outlook's history extends beyond the header container across siblings.
        const tail = Array.from(body.querySelectorAll(tailSelector)).find(node => !node.closest('details[data-mailingo-quote]'));
        if (tail) {
            const range = document.createRange();
            range.setStartBefore(tail);
            range.setEnd(body, body.childNodes.length);
            fold(range);
        } else if (!containers.length) {
            // Unstructured HTML / <pre> reply separators: match whole lines only.
            const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
                if (node.parentElement.closest('script,style,summary,details[data-mailingo-quote]')) continue;
                const lines = node.textContent.split('\n');
                let offset = 0;
                let found = false;
                for (const line of lines) {
                    if (attribution(line)) {
                        const range = document.createRange();
                        range.setStart(node, offset);
                        range.setEnd(body, body.childNodes.length);
                        fold(range);
                        found = true;
                        break;
                    }
                    offset += line.length + 1;
                }
                if (found) break;
            }
        }
        return nextID;
    }
    """#
}
