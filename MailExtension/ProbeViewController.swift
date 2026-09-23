import AppKit
import MailKit

/// 点击横幅/头部图标后 Mail 呈现的视图。
///
/// 它不是产品 UI（产品侧栏是自绘的 NSPanel），而是**确认"点对了哪一封"**的凭据：
/// 显示出邮件主题、发件人、时间和 ID。会话里来回好几封时，
/// 这是最直接的验证方式 —— 点的是哪一封，这里就该显示哪一封。
final class ProbeViewController: MEExtensionViewController {

    enum Reason: String {
        case headerIcon = "邮件头部扩展图标"
        case messageContext = "横幅（带 messageContext）"
        case bannerAction = "横幅主操作按钮"
    }

    private let reason: Reason
    private let message: StoredMessage?

    init(reason: Reason, message: StoredMessage?) {
        self.reason = reason
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))

        let title = NSTextField(labelWithString: "Mailingo")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: "触发方式：\(reason.rawValue)")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let body = NSTextField(wrappingLabelWithString: Self.report(for: message))
        body.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        body.isSelectable = true

        let openButton = NSButton(
            title: "在 Mailingo 里打开",
            target: self,
            action: #selector(openInApp)
        )
        openButton.bezelStyle = .rounded
        openButton.isEnabled = message != nil

        let stack = NSStackView(views: [title, subtitle, body, openButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20)
        ])

        self.view = root
    }

    @objc private func openInApp() {
        guard let id = message?.id,
              let url = URL(string: "mailingo://translate?id=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func report(for message: StoredMessage?) -> String {
        guard let message else {
            return """
            没能确定是哪一封邮件。

            这条路径（头部图标）拿不到 Mail 回传的 context，
            而仓库里目前还没有任何已捕获的邮件。

            请改用邮件顶部的「翻译」横幅 —— 那条路径能精确知道点的是哪一封。
            """
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        return """
        邮件 ID : \(message.id)
        主题    : \(message.subject.isEmpty ? "(无主题)" : message.subject)
        发件人  : \(message.from.isEmpty ? "(未知)" : message.from)
        时间    : \(message.date.map(formatter.string(from:)) ?? "(未知)")
        大小    : \(message.byteCount) 字节

        已同步到 Mailingo，翻译结果会显示在其窗口中。
        """
    }
}
