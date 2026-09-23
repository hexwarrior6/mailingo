import EmailCore
import SwiftUI

/// 带标题与边框的预览窗格。
///
/// 真正的渲染在 `EmailWebView` 里（处理 `cid:` 内嵌图、阻断外部内容、链接跳浏览器）。
struct PreviewPane: View {

    let title: String
    let subtitle: String
    let html: String
    /// MIME 里解出来的内嵌资源，用来显示 `cid:` 引用的图片。
    let inlineResources: [String: InlineResource]
    /// 是否允许加载外部图片（默认关闭，和 Mail 行为一致）。
    let allowsRemoteContent: Bool
    var accent: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            EmailWebView(
                html: html,
                inlineResources: inlineResources,
                allowsRemoteContent: allowsRemoteContent
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(accent.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
