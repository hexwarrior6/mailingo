import SwiftUI
import WebKit

/// 把一段 HTML 渲染出来。M3 阶段只用来做并排预览 —— 正式的邮件渲染器在 M5。
struct HTMLPreviewView: NSViewRepresentable {

    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 邮件 HTML 里的脚本一律不执行。
        // 预览阶段我们也不需要 JS（渐进更新要等 M5 再接）。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 只在内容真的变了才重新加载，否则 SwiftUI 每次刷新都会把页面重置，
        // 滚动位置也跟着没了。
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var loadedHTML: String?
    }
}

/// 带标题与边框的预览窗格。
struct PreviewPane: View {
    let title: String
    let subtitle: String
    let html: String
    var accent: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HTMLPreviewView(html: html)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(accent.opacity(0.35), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
