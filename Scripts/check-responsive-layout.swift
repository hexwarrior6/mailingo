// Compile with EmailCore sources. Exercises actual WebKit layout without network requests.
import AppKit
import WebKit

private final class PosterHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let query = URLComponents(url: task.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let width = query.first { $0.name == "w" }?.value ?? "203"
        let height = query.first { $0.name == "h" }?.value ?? (task.request.url?.host == "poster1" ? "300" : "280")
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='\(width)' height='\(height)'><rect width='100%' height='100%' fill='#b21f2f'/></svg>"
        let data = Data(svg.utf8)
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "image/svg+xml", expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@main
private final class LayoutCheck: NSObject, WKNavigationDelegate {
    private let handler = PosterHandler()
    private var webView: WKWebView!
    private var window: NSWindow!
    private var cases: [(Int, Bool)] = [1000, 610, 360, 280].flatMap { [($0, false), ($0, true)] }
    private var input = ""

    static func main() {
        let check = LayoutCheck()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        check.start()
        // Keep delegate alive throughout the AppKit run loop.
        withExtendedLifetime(check) { app.run() }
    }

    private func start() {
        if CommandLine.arguments.count > 1 {
            input = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        } else {
            input = "<html><head><meta charset='utf-8'></head><body>" + (1...3).map { index in
                """
                <table align="center" style="width:610px"><tr>
                <td style="width:203.323px;vertical-align:top">
                <table style="width:100%"><tr><td><table style="width:100%"><tr><td style="width:203.323px">
                <a href="https://example.test/event"><img width="203" style="width:203.323px;height:auto;display:block" src="mailingo-cid://poster\(index)"></a>
                </td></tr></table></td></tr></table></td>
                <td style="width:406.677px;vertical-align:top"><table style="width:100%" cellpadding="10"><tr><td>
                <h3>活动 \(index)</h3><p>\(String(repeating: "一起参加校园活动，了解详情。", count: index * 4))</p>
                </td></tr></table></td></tr></table>
                """
            }.joined() + """
            <table width="610" cellspacing="0" cellpadding="0" align="center"><tr>
            <td width="407">Campus news</td><td width="101">Find us</td><td width="102">
            <table width="100%" cellpadding="5"><tr><td><table width="69" cellspacing="0" cellpadding="0"><tr>
            <td><img width="32" src="mailingo-cid://social1"></td>
            <td style="padding-left:5px"><img width="32" src="mailingo-cid://social2"></td>
            </tr></table></td></tr></table></td></tr></table></body></html>
            """
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(handler, forURLScheme: "mailingo-cid")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1100), configuration: config)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { fatalError("Layout check timed out") }
        next()
    }

    private func next() {
        guard let (width, badges) = cases.first else {
            print("PASS: all layout cases passed")
            exit(0)
        }
        webView.setFrameSize(NSSize(width: width, height: 1100))
        var html = input
        if badges {
            let regex = try! NSRegularExpression(pattern: #"src="mailingo-cid://([^"]+)""#)
            let keys = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match -> (String, ImageTranslationOverlay.Badge)? in
                guard let range = Range(match.range(at: 1), in: html) else { return nil }
                return (String(html[range]), .translate)
            }
            html = ImageTranslationOverlay.inject(into: html, badges: Dictionary(uniqueKeysWithValues: keys))
        }
        webView.loadHTMLString(EmailResponsiveLayout.inject(into: html), baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.measure() }
    }

    private func measure() {
        if input.contains("qr-code") { measureTicket(); return }
        webView.evaluateJavaScript("""
        (() => {
          const images = [...document.querySelectorAll('img[width="203"]')];
          const boxes = images.map(i => i.getBoundingClientRect());
          const textX = images.map(i => {
            let cell = i.closest('td');
            while (cell && !cell.nextElementSibling) cell = cell.parentElement.closest('td');
            return cell?.nextElementSibling?.getBoundingClientRect().x ?? -1;
          });
          return {widths: boxes.map(r => r.width), textX,
            loaded: images.every(i => i.complete && i.naturalWidth > 0),
            outside: [...document.querySelectorAll('table')].filter(t => {
              const r = t.getBoundingClientRect(); return r.width > 0 && (r.right > innerWidth + 1 || r.left < -1);
            }).map(t => ({html:t.outerHTML.slice(0,180), text:t.innerText.slice(0,160), x:t.getBoundingClientRect().x, width:t.getBoundingClientRect().width})),
            overflow: document.documentElement.scrollWidth - innerWidth};
        })()
        """) { result, error in
            guard error == nil, let result = result as? [String: Any],
                  let widths = result["widths"] as? [Double], widths.count >= 3,
                  let textX = result["textX"] as? [Double],
                  result["loaded"] as? Bool == true,
                  (result["outside"] as? [[String: Any]])?.isEmpty == true,
                  (widths.max()! - widths.min()!) < 1,
                  widths.min()! > 40,
                  textX.min()! > 0, (textX.max()! - textX.min()!) < 1,
                  (result["overflow"] as? Double ?? 999) <= 1 else {
                print("FAIL: \(self.cases[0]): \(String(describing: result)) \(String(describing: error))")
                exit(1)
            }
            print("PASS: \(self.cases[0]), \(widths.count) posters, width=\(widths[0]), text x=\(textX[0])")
            self.cases.removeFirst()
            self.next()
        }
    }

    private func measureTicket() {
        webView.evaluateJavaScript("""
        (() => {
          const qr = document.querySelector('.qr-code');
          const logo = document.querySelector('img[width="150"]');
          const wallet = document.querySelector('img[width="111"]');
          const left = qr.closest('table[width="260"]');
          const right = [...document.querySelectorAll('table[width="330"]')][0];
          return {qr: qr.getBoundingClientRect().width, logo: logo.getBoundingClientRect().width,
            wallet: wallet.getBoundingClientRect().width,
            left: left.getBoundingClientRect().x, right: right.getBoundingClientRect().x,
            loaded: [...document.images].every(i => i.complete && i.naturalWidth > 0),
            overflow: document.documentElement.scrollWidth - innerWidth,
            outside: [...document.querySelectorAll('table')].filter(t => {
              const r = t.getBoundingClientRect(); return r.width > 0 && (r.right > innerWidth + 1 || r.left < -1);
            }).length};
        })()
        """) { result, error in
            let current = self.cases[0]
            guard error == nil, let values = result as? [String: Any],
                  values["loaded"] as? Bool == true,
                  abs((values["qr"] as? Double ?? 0) - 200) < 1,
                  abs((values["logo"] as? Double ?? 0) - 150) < 1,
                  abs((values["wallet"] as? Double ?? 0) - 111) < 1,
                  (values["outside"] as? Int) == 0,
                  (values["overflow"] as? Double ?? 999) <= 1,
                  current.0 < 640 || (values["right"] as? Double ?? 0) > (values["left"] as? Double ?? 0) + 200 else {
                print("FAIL ticket: \(current): \(String(describing: result)) \(String(describing: error))")
                exit(1)
            }
            print("PASS ticket: \(current): \(values)")
            if current == (1000, true) {
                self.webView.takeSnapshot(with: nil) { image, _ in
                    if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: ".build/admissions-layout-preview.png"))
                    }
                    self.cases.removeFirst()
                    self.next()
                }
            } else {
                self.cases.removeFirst()
                self.next()
            }
        }
    }
}
