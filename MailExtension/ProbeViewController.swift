import AppKit
import MailKit

/// S0 探针的 UI。
///
/// 它的唯一使命是**证明 Mail 真的把我们的视图控制器呈现出来了**，
/// 并且顺手把扩展进程看到的数据展示出来（原始 MIME 长度 + 日志尾部）。
///
/// 这不是产品 UI —— 产品侧栏是自绘的 NSPanel（见 docs/IMPLEMENTATION_PLAN.md §4.7）。
final class ProbeViewController: MEExtensionViewController {

    enum Reason: String {
        case headerIcon = "邮件头部扩展图标"
        case messageContext = "横幅 / 头部图标（messageContext）"
        case bannerAction = "横幅主操作按钮"
    }

    private let reason: Reason
    private let context: Data

    init(reason: Reason, context: Data) {
        self.reason = reason
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))

        let title = NSTextField(labelWithString: "✅ S0 探针成功：Mail 呈现了我们的视图控制器")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString:
            "触发方式：\(reason.rawValue)\ncontext：\(String(data: context, encoding: .utf8) ?? "<非 UTF-8>")"
        )
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let body = NSTextView()
        body.isEditable = false
        body.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        body.string = Self.buildReport()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = body
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(
            title: "复制报告",
            target: self,
            action: #selector(copyReport)
        )

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        root.addSubview(scroll)
        root.addSubview(copyButton)
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -10),

            copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        self.view = root
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.buildReport(), forType: .string)
    }

    private static func buildReport() -> String {
        var out = ""

        out += "── 原始 MIME ──────────────────────────────\n"
        if let data = try? Data(contentsOf: ProbeLog.lastMessageURL) {
            out += "已落盘 \(data.count) bytes → \(ProbeLog.lastMessageURL.path)\n"
            out += "看上去是完整邮件？\(looksLikeFullMessage(data) ? "是（含头部 + 正文分隔）" : "⚠️ 否")\n\n"
            out += "前 1200 字节预览：\n"
            let preview = data.prefix(1200)
            out += String(data: preview, encoding: .utf8)
                ?? String(data: preview, encoding: .isoLatin1)
                ?? "<无法解码>"
            out += "\n"
        } else {
            out += "⚠️ 没有找到 \(ProbeLog.lastMessageURL.path)\n"
            out += "说明 decodedMessage(forMessageData:) 还没被调用过。\n"
        }

        out += "\n── 事件日志（尾部 6000 字符）────────────────\n"
        let log = ProbeLog.shared.readLog()
        out += log.count > 6000 ? String(log.suffix(6000)) : log
        out += "\n"
        return out
    }

    /// 粗判是否是一封完整的 MIME 邮件：有头部区、且存在头部/正文分隔空行。
    private static func looksLikeFullMessage(_ data: Data) -> Bool {
        guard data.count > 64 else { return false }
        let head = data.prefix(16384)
        guard let text = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .isoLatin1) else { return false }
        return text.contains("\n\n") || text.contains("\r\n\r\n")
    }
}
