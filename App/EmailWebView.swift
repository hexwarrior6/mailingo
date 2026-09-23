import SwiftUI
import WebKit

import EmailCore

/// 渲染一封邮件的 HTML。
///
/// 这是"像邮件客户端一样自己渲染"的那一层。它负责三件 WKWebView 默认做不了的事：
///
/// 1. **内嵌图片（`cid:`）** —— HTML 里写的是 `src="cid:logo@example"`，
///    WebKit 不知道 `cid:` 是什么协议，图会完全显示不出来。
///    这里先把 `cid:` 改写成自定义 scheme，再由 `WKURLSchemeHandler` 喂字节。
/// 2. **外部内容默认阻断** —— 远程图片是最常见的追踪手段
///    （发件人靠它知道你什么时候、看了几次）。和 Mail 一样默认不加载，
///    用户点了「载入远程图片」才放行。用 `WKContentRuleList` 在 WebKit 层拦，
///    而不是靠改写 HTML —— 这样 CSS 背景、字体、追踪像素也一并挡住。
/// 3. **链接跳浏览器** —— 邮件里的链接绝不能在这个小窗格里导航走。
///
/// 另外 `allowsContentJavaScript = false`：邮件里的脚本一律不执行。
/// 有了这一条就不需要再去 HTML 里"剥离 `<script>`"了 —— 那是重复的防线。
struct EmailWebView: NSViewRepresentable {

    let html: String
    /// MIME 里解出来的内嵌资源（`Content-ID` → 字节）。
    let inlineResources: [String: InlineResource]
    /// 是否允许加载外部（http/https）内容。
    let allowsRemoteContent: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(inlineResources: inlineResources)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 邮件里的脚本一律不执行。这一条就是脚本防护，不需要再手动剥 <script>。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: CIDReferenceRewriter.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false

        context.coordinator.attach(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            html: html,
            inlineResources: inlineResources,
            allowsRemoteContent: allowsRemoteContent
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {

        /// 连接阶段就设成 nil，让 `scheme` 与 `LocalizedError` 的说法保持一致
        private static let blockRuleListIdentifier = "com.zhuyuhao.Mailingo.block-remote-content"
        /// 远程内容拦截规则。编译一次后复用。
        private static var blockRuleList: WKContentRuleList?

        private var inlineResources: [String: InlineResource]
        private weak var webView: WKWebView?

        private var currentHTML = ""
        private var loadedRenderedHTML: String?
        private var appliedRemotePolicy: Bool?
        /// 拦截规则是否**已经真正挂到 controller 上**（注意：不是"编译好了"）。
        private var isBlockingInPlace = false

        init(inlineResources: [String: InlineResource]) {
            self.inlineResources = inlineResources
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func update(html: String, inlineResources: [String: InlineResource], allowsRemoteContent: Bool) {
            self.currentHTML = html
            self.inlineResources = inlineResources

            if appliedRemotePolicy != allowsRemoteContent {
                appliedRemotePolicy = allowsRemoteContent
                configureRemoteContentPolicy(allowsRemoteContent)
                // 策略变化必须重新加载才会对已发出的请求生效
                loadedRenderedHTML = nil
            }

            reloadIfNeeded()
        }

        // MARK: 加载

        private func reloadIfNeeded() {
            guard let webView else { return }

            // ★ 要拦截、但规则还没挂上 —— **先别加载**。
            //
            // 规则表的编译是异步的。早先这里没等它，于是首次渲染会在
            // 规则就位之前把 HTML 加载出去：那几毫秒里远程图片的请求**已经发出去了**，
            // 发件人该知道的已经知道了。"拦截"却没拦住，等于白做。
            // 宁可多等一个异步回合，也不能先放请求出去。
            if appliedRemotePolicy == false, !isBlockingInPlace { return }

            let rendered = CIDReferenceRewriter.rewrite(currentHTML)
            guard loadedRenderedHTML != rendered else { return }
            loadedRenderedHTML = rendered
            webView.loadHTMLString(rendered, baseURL: nil)
        }

        // MARK: 远程内容策略

        private func configureRemoteContentPolicy(_ allows: Bool) {
            guard let webView else { return }
            let controller = webView.configuration.userContentController

            // 先把可能存在的旧规则摘掉，避免叠加
            if let existing = Self.blockRuleList {
                controller.remove(existing)
            }
            isBlockingInPlace = false

            // 放行：摘掉规则就行
            guard !allows else { return }

            if let list = Self.blockRuleList {
                // 已经编译过，直接挂上
                controller.add(list)
                isBlockingInPlace = true
            } else {
                Self.compileBlockRuleList { [weak self] list in
                    guard let self else { return }
                    Self.blockRuleList = list

                    // 编译期间策略可能又被切走了，要重新确认
                    guard let list, let webView = self.webView,
                          self.appliedRemotePolicy == false else { return }

                    webView.configuration.userContentController.add(list)
                    self.isBlockingInPlace = true
                    self.loadedRenderedHTML = nil
                    // 规则就位了，这次才真的加载
                    self.reloadIfNeeded()
                }
            }
        }

        private static func compileBlockRuleList(completion: @escaping (WKContentRuleList?) -> Void) {
            // 拦掉所有 http/https 子资源。自定义 scheme 不受影响
            // （`url-filter` 只匹配 http/https 开头）。
            let json = """
            [{
                "trigger": { "url-filter": "^https?://" },
                "action": { "type": "block" }
            }]
            """

            WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: blockRuleListIdentifier,
                encodedContentRuleList: json
            ) { list, error in
                if let error {
                    NSLog("[Mailingo] 远程内容拦截规则编译失败：\(error.localizedDescription)")
                }
                DispatchQueue.main.async { completion(list) }
            }
        }

        // MARK: WKURLSchemeHandler —— 把 cid: 变成真实图片

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  let cid = CIDReferenceRewriter.contentID(from: url) else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }

            guard let resource = inlineResources[cid] else {
                // 找不到对应部件：安静失败即可，不要弹错（邮件里常有无主的 cid 引用）
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }

            let response = URLResponse(
                url: url,
                mimeType: resource.mimeType,
                expectedContentLength: resource.data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(resource.data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            // 没有需要清理的异步工作
        }

        // MARK: WKNavigationDelegate

        /// 邮件里的链接一律交给默认浏览器打开，绝不在这个小窗格里导航走。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // 首次加载（loadHTMLString）没有 navigationType .linkActivated
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if url.scheme == CIDReferenceRewriter.scheme {
                    decisionHandler(.allow)
                } else {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                }
                return
            }
            decisionHandler(.allow)
        }
    }
}
