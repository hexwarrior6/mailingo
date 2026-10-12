// Native WebKit regression check for reply-history disclosures.
// make check-reply-quotes
// Uses synthetic mail only; verifies app scripts while email scripts stay disabled.
import AppKit
import WebKit
import Foundation

@MainActor
final class FoldCheck: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    var index = 0
    var restoring = false
    let cases: [(String, String, Int)] = [
        ("Outlook", "<div><p id='current'>Current reply</p><div id='divRplyFwdMsg'><b>From:</b> Alex</div><p id='old'>Old reply</p></div>", 1),
        ("Apple inline", "<p id='current'>First reply</p><div>On Monday, Alex wrote:</div><blockquote type='cite'><p id='old'>Old reply</p><blockquote type='cite'>Older reply</blockquote></blockquote><p id='inline'>Another current reply</p>", 1),
        ("Gmail", "<p id='current'>Current reply</p><div class='gmail_quote'><p id='old'>Old reply</p></div>", 1),
        ("Plain inline", "<p id='current'>Current reply<br><span class='gmail_quote' id='old'>&gt; Old reply</span><br><span class='gmail_quote'>&gt; Older reply</span><br><span id='inline'>Another current reply</span></p>", 1),
        ("Plain separator", "<p id='current'>Current reply<br>On Monday, Alex wrote:<br><span id='old'>Old reply</span></p>", 1),
        ("Ordinary quote", "<p id='current'>Review this quote</p><blockquote id='old'>Literary quote</blockquote>", 0),
        ("Table tail", "<table><tbody><tr><td><p id='current'>Current reply</p><div id='divRplyFwdMsg'>From: Alex</div><p id='old'>Old reply</p></td></tr></tbody></table>", 1)
    ]
    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 620, height: 300), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        window.orderFrontRegardless()
        webView.navigationDelegate = self
    }
    func load() {
        let fixture = cases[index]
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: ReplyQuoteCollapser.script(expandedIDs: restoring ? ["0"] : []), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        webView.loadHTMLString("<html><body style='font:15px -apple-system; padding:18px'><h3>\(fixture.0)</h3>\(fixture.1)<script>document.body.dataset.untrusted = 'ran'</script></body></html>", baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.querySelectorAll('details[data-mailingo-quote]').length") { result, error in
            guard error == nil, let count = result as? Int, count == self.cases[self.index].2 else {
                print("FAIL collapse \(self.cases[self.index].0): \(String(describing: result)) \(String(describing: error))")
                exit(1)
            }
            if self.restoring {
                webView.evaluateJavaScript(ReplyQuoteCollapser.expandedStateScript) { result, error in
                    guard error == nil, (result as? [String]) == ["0"] else { print("FAIL restored disclosure"); exit(1) }
                    print("PASS restored expanded state: \(self.cases[self.index].0)")
                    self.advance()
                }
                return
            }
            webView.evaluateJavaScript("""
            (() => {
                const d = document.querySelector('details[data-mailingo-quote]');
                const old = document.getElementById('old');
                const current = document.getElementById('current');
                const inline = document.getElementById('inline');
                const closed = !d || !d.open;
                const currentVisible = !current.closest('details[data-mailingo-quote]');
                const inlineVisible = !inline || !inline.closest('details[data-mailingo-quote]');
                const oldHidden = !d || !!old.closest('details[data-mailingo-quote]');
                if (d) d.querySelector('summary').click();
                const opens = !d || d.open;
                if (d) d.querySelector('summary').click();
                const closes = !d || !d.open;
                return closed && currentVisible && inlineVisible && oldHidden && opens && closes && !document.body.dataset.untrusted;
            })()
            """) { result, error in
                guard error == nil, (result as? Bool) == true else { print("FAIL behavior \(self.cases[self.index].0): \(String(describing: result)) \(String(describing: error))"); exit(1) }
                print("PASS \(self.cases[self.index].0): default closed, toggle works, current reply visible, email scripts disabled")
                if self.index == 0 {
                    webView.takeSnapshot(with: nil) { image, _ in
                        if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/mailingo-fold-preview.png")) }
                        self.advance()
                    }
                } else { self.advance() }
            }
        }
    }
    func advance() {
        if !restoring && cases[index].2 > 0 {
            restoring = true
            load()
            return
        }
        restoring = false
        index += 1
        if index == cases.count { print("PASS all 7 WebKit fixtures"); exit(0) }
        load()
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let check = FoldCheck()
        check.load()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL timed out"); exit(1) }
        app.run()
    }
}
