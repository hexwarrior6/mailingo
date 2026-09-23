# Mailingo 实施方案（V1）

> 本文是实现 `docs/PRODUCT.md` 的技术方案。所有"已核实"结论均来自本机 SDK 头文件、Mail 的 sdef 以及真机实验，不是推测。

---

## 0. 结论先行：3 个必须先纠正的事实

在读方案之前，有 3 件事必须先确认，因为它们直接改变产品形态。

### ① 「Mail 内的 Translate 按钮」：**部分可行，但不在工具栏上**（已修正）

> ⚠️ 本节初稿曾断言"完全做不到"，**这个结论是错的**。经查 `MEComposeSession.h` / `MEMessageSecurityHandler.h` / `MEDecodedMessage.h` 与 Xcode 的 Mail Extension 模板后修正如下。

MailKit 的扩展点确实只有 4 个（`MEExtension.h`）：

```objc
- (id<MEComposeSessionHandler>)handlerForComposeSession:   // 写信窗口 —— 有按钮 + 自定义 UI
- (id<MEMessageActionHandler>)handlerForMessageActions;    // 邮件"已下载"时的动作（规则触发）
- (id<MEContentBlocker>)handlerForContentBlocker;          // 内容拦截
- (id<MEMessageSecurityHandler>)handlerForMessageSecurity; // ★ 加密/签名 —— 阅读窗格里有 UI 钩子
```

**写信窗口**（`MEComposeSessionHandler`）确实能加按钮并弹出自定义视图：

```objc
/// A view controller to be presented in Mail compose window.
/// Mail will call this method when user clicks on the extension's button.
- (MEExtensionViewController *)viewControllerForSession:(MEComposeSession *)session;
```

但那只作用于**写信**，不是"打开一封收到的外语邮件"这个场景。

**真正的发现是 Message Security 扩展点**（`MEMessageSecurityHandler`）——它在**阅读窗格**里有 UI 钩子：

```objc
/// Invoked by Mail to request a subclass of MEExtensionViewController
/// when the user clicks a banner or on the extensions icon in the message header view.
- (nullable MEExtensionViewController *)extensionViewControllerForMessageContext:(NSData *)context;

/// Invoked when the primary action for the message banner is clicked.
- (void)primaryActionClickedForMessageContext:(NSData *)context
                            completionHandler:(void (^)(MEExtensionViewController * _Nullable))completionHandler;
```

配套的 `MEDecodedMessage`：

```objc
/// Suggestion information used to populate a suggestion banner at the top of the
/// message view. Clicking on the action associated with the suggestion banner will
/// present the extension's view controller for the provided message context.
@property (nonatomic, nullable, readonly) MEDecodedMessageBanner *banner;   // title + primaryActionTitle
@property (nonatomic, nullable, readonly) NSData *context;                  // 回传给 view controller
```

而且解码入口**直接把整封原始邮件交给你**：

```objc
/// This is invoked while a message is being decoded.
/// @param data - The original data for the message.
- (nullable MEDecodedMessage *)decodedMessageForMessageData:(NSData *)data;
```

**所以 Mail 扩展能提供的，是在阅读窗格里的：**
1. 邮件**顶部横幅**（自定义标题 + 主操作按钮，如「翻译此邮件」）；
2. 邮件**头部的一个扩展图标**；
3. 点击后由 Mail 呈现我们自己的 `MEExtensionViewController`（完整自定义 UI，就在 Mail 窗口内）；
4. **外加整封原始 MIME**（`decodedMessageForMessageData:` 的 `data` 参数）。

> 这条路的最大价值：**完全不需要 Automation / Apple Events 权限，也不碰 `~/Library/Mail`** —— 数据是 Mail 主动递给扩展的。权限模型比架构 A 干净得多。

**但它拿不到的：**
- **可调宽度、跟随 Mail 窗口的吸附式侧栏**。呈现方式（横幅 / sheet / 弹窗）由 Mail 决定，我们控制不了 frame，也拿不到「Mail 窗口移动/缩放」的事件。这是 PRODUCT.md §3 的核心要求。
- 语义上这是在**借用**为 S/MIME / PGP 设计的扩展点。对一封普通的未加密未签名邮件返回非 nil 的 `MEDecodedMessage`，等于宣称"我解码了它"，Mail 会据此渲染安全状态 UI —— 有可见的语义与观感风险。
- **调用时机未验证**：文档措辞是"invoked while a message is being decoded… if the extension is not needed it should return nil"，暗示 Mail 会询问，但对**普通未加密邮件**是否真的调用，必须实验确认（见 Spike S0）。这是本路线唯一的 go/no-go 未知项。

> **修正后的结论**：PRODUCT.md 的"Mail 内 Translate 按钮"**可以**做成"横幅 + 头部图标"而非工具栏按钮；但"吸附式可调宽侧栏"仍必须由我们自己的 NSPanel 承担。→ 见 §2.5 的三种架构对比，**推荐架构 C（扩展做入口 + 容器 App 做侧栏）**。

### ② Apple Translation 在 macOS 15 上只能从 SwiftUI 拿到 session

`Translation.framework` 的 `TranslationSession` 在 macOS 15 上**没有公开的 init**。SDK swiftinterface 里唯一的构造器是：

```swift
@available(iOS 26.0, macOS 26.0, *)
convenience public init(installedSource source: Locale.Language, target: Locale.Language?)
```

macOS 15 上唯一的入口是 SwiftUI 的跨导入 overlay `_Translation_SwiftUI`：

```swift
@available(iOS 18.0, macOS 15.0, *)
public func translationTask(_ configuration: TranslationSession.Configuration?,
                            action: @escaping (_ session: TranslationSession) async -> Void) -> some View
```

> **结论**：需要一个**隐藏的 SwiftUI 宿主视图**（`.translationTask`）来长期持有一个 session，再把它桥接成一个普通的 `async` 服务给全 App 用。这是本方案里最"不显然"的一块，见 §4.5。

### ③ 跟随 Mail 窗口**不需要任何权限**（已实测）

本机实测 `CGWindowListCopyWindowInfo`：

```
owner=邮件  bounds=YES 1470x854  name=<nil>
owner=访达  bounds=YES 920x492   name=<nil>
=> 窗口 bounds / PID 无需「屏幕录制」权限即可读取，只有 kCGWindowName 为 nil
```

**但踩到一个真实的坑**：`kCGWindowOwnerName` 是**本地化**的 —— 中文系统上 Mail 显示为 `邮件` 而不是 `Mail`。任何 `owner == "Mail"` 的判断都会在非英文系统上失效。

> **结论**：必须用 `NSRunningApplication(bundleIdentifier: "com.apple.mail").processIdentifier` → 匹配 `kCGWindowOwnerPID`。
> 因此"跟随 Mail 移动/缩放/最小化/隐藏"**零权限**即可实现。

---

## 1. 已核实的环境与 API 事实

| 项目 | 值 | 来源 |
|---|---|---|
| 本机系统 | macOS 15.7.2 (24G325) | `sw_vers` |
| Xcode / Swift | 26.0.1 / Swift 6.2 | `xcodebuild -version` |
| SDK | macOS 26.0（部署目标建议 macOS 15.0） | `xcodebuild -showsdks` |
| MailKit 扩展点 | 仅 4 个 handler，无阅读窗格 API | SDK `MailKit.framework/Headers/MEExtension.h` |
| Mail AppleScript | `message viewer.selected messages`、`message.source`(原始 MIME)、`all headers`、`message id` | `/System/Applications/Mail.app/Contents/Resources/Mail.sdef` |
| Translation 批量 API | `translations(from: [Request]) async throws -> [Response]`，`Request.clientIdentifier` 用于对账 | SDK `Translation.swiftinterface` |
| macOS 26 新增 | `TranslationSession(installedSource:target:)`、`isReady`、`canRequestDownloads`、`cancel()`、`TranslationError.notInstalled` | 同上 |
| 窗口 bounds | 零权限可读；窗口标题需屏幕录制 | 本机实测 |

**AppleScript 实测结果**：从 shell 直接 `osascript` 控制 Mail 返回 `-10004 权限违例`。这是预期行为 —— 未签名/无 `NSAppleEventsUsageDescription` 的进程拿不到 Automation 授权。**这恰恰说明 §5 的签名与 Info.plist 工作是刚需，不是可选项。**

---

## 2. 产品形态调整（相对 PRODUCT.md 的差异）

| PRODUCT.md 原意 | 调整后 | 原因 |
|---|---|---|
| Mail 内 Translate 按钮 | 改为 **Mail 阅读窗格横幅 / 头部扩展图标**（架构 C）+ ⌥T 兜底 | ① MailKit **不能**加到工具栏，但 Message Security 扩展点能在阅读窗格里放 UI |
| Sidebar 吸附在 Mail 右侧 | **仍由自绘 NSPanel 承担**（扩展无法提供可调宽侧栏） | ① Mail 控制扩展 UI 的呈现方式与 frame |
| 跟随 Mail 移动/缩放/隐藏 | ✅ 保留，用 CGWindowList 轮询，**零权限** | ③ 已实测可行 |
| 侧栏可调宽度 | ✅ 保留 | — |
| 读取当前邮件 | ✅ `message viewer.selected messages[0].source` | 已核实 sdef |
| 不用私有 API / 不读 ~/Library/Mail | ✅ 严格遵守 | — |

### 侧栏摆放的两种模式

Mail 通常是**全宽/最大化**的（本机实测 1470×854 ≈ 满屏）。所以"并排显示"必须先给 Mail 让位：

- **模式 A（V1 默认，零额外权限）**：面板贴在 Mail 右缘，宽度可调（默认 420pt），超出屏幕时向内 clamp，视觉上覆盖 Mail 右半部分。
- **模式 B（V1.1 可选，需 Accessibility）**：读取 Mail 窗口 `AXSize`/`AXPosition`，先把 Mail 缩窄腾出空间，再把面板精确放进空位；关闭面板时恢复 Mail 原尺寸。这是最接近"Apple 原生侧栏"的观感，但会改动用户窗口，必须做成**显式开关**。

> 建议：V1 只做 A，把 B 作为 V1.1 的 opt-in。理由见 §5（Accessibility 与沙盒互斥，会锁死分发渠道）。

---

## 2.5 三种架构对比：入口在 Mail 内到底怎么落

因为 §0① 的修正，触发入口出现了一个真正的分叉，必须选清楚。

### 架构 A：纯独立 App（自绘侧栏）

```
⌥T 快捷键 / 菜单栏  →  Apple Events 读邮件  →  翻译  →  自绘 NSPanel 吸附 Mail 右侧
```

| | |
|---|---|
| ✅ | 完全控制 UI：真侧栏、宽度可调、跟随 Mail 移动/缩放/最小化 |
| ❌ | 入口不在 Mail 界面内 |
| ❌ | 需要 **Automation 权限**（Apple Events） |
| ❌ | 依赖 Mail 的 AppleScript 字典（未来可能变） |

### 架构 B：纯 Mail 扩展（UI 交给 Mail 托管）

```
Mail 阅读窗格横幅 / 头部图标  →  扩展拿到原始 MIME  →  翻译  →  扩展自己的 ViewController（Mail 呈现）
```

| | |
|---|---|
| ✅ | 入口真的在 Mail 里 |
| ✅ | **零 Automation 权限**、不碰 `~/Library/Mail`、Mail 主动递原始 MIME |
| ❌ | **拿不到可调宽度的吸附侧栏**（呈现方式由 Mail 决定） |
| ❌ | 借用 S/MIME 扩展点，对普通邮件伪装"已解码"有观感/语义风险 |
| ❌ | 普通未加密邮件的调用时机未验证（Spike S0） |
| ❌ | 用户必须在 Mail → 设置 → 扩展 里手动启用 |

### 架构 C：扩展（入口 + 数据源）+ 容器 App（侧栏 UI）★ 已由 S0 确认采用

> **状态：✅ S0 实测通过（2026-09-23），确定采用架构 C。** 详见 `docs/S0-PROBE.md`。

```
Mail 阅读窗格横幅 / 头部图标
        │  点击
        ▼
  Mail 扩展（appex）── 拿到原始 MIME（零权限）
        │  写 App Group 共享容器 + 唤醒容器 App
        ▼
  容器 App ── 翻译 ── 自绘 NSPanel 吸附在 Mail 右侧（宽度可调、跟随窗口）
```

这是唯一能**同时**满足 PRODUCT.md §2（Mail 内入口）和 §3（吸附式可调宽侧栏）的架构。

- **入口**：扩展提供 Mail 内的横幅/图标 → 满足"像 Apple 原生"的观感。
- **数据**：原始 MIME 由 Mail 递给扩展，**不需要 Automation 权限** —— 比架构 A 的权限模型干净。
- **UI**：侧栏仍是我们的 NSPanel，保留宽度可调 + 跟随 Mail 窗口的能力（CGWindowList，零权限）。
- **降级**：⌥T 全局快捷键仍然保留，作为"扩展未启用 / 调用时机不成立"时的兜底入口 —— 两个入口共用同一条管线，成本很低。

**通信方式**：App Group 共享容器（`~/Library/Group Containers/<group-id>/`）写一个 `PendingTranslationRequest` JSON（含 raw MIME 路径 + messageID + 时间戳），再用 `NSWorkspace.openApplication` 或 Darwin 通知唤醒容器 App；容器 App 读走并显示侧栏。

**关键工程注意**：Mail 扩展是独立进程。传输几 MB 的原始 MIME **不要走 XPC 消息体或 Darwin 通知的 payload**（有大小限制），而是写文件到 App Group 目录，通知里只传路径。

**未解决的前提（必须 Spike S0 先验）**：`decodedMessageForMessageData:` 对**普通未加密未签名邮件**是否会被调用、且返回非 nil 后横幅是否真的显示。若不成立，则退回架构 A。

> **推荐路线**：**M0 先只验 S0**。若 S0 通过 → 做架构 C（工作量 +3~4 天）。若 S0 不通过 → 架构 A 作为 V1，扩展留作 V2。

---

## 3. 架构设计

### 3.1 模块划分（SPM 多 target，让编译器强制边界）

PRODUCT.md §13 的目录是合理的，这里落成**真正的 SPM 模块**，而不是文件夹 —— 这样"Parser 不依赖 UI""Cache 不依赖具体模型"是编译器保证的，不是靠自觉。

```
mailingo/
├── project.yml                        # XcodeGen 生成 xcodeproj（可 review、无合并冲突）
├── App/                               # 唯一有 @main 的 target
│   ├── MailingoApp.swift
│   ├── AppDependencies.swift           # 组合根：唯一知道所有具体类型的地方
│   ├── MenuBar/                        # MenuBarExtra
│   └── Resources/Info.plist, *.entitlements, Assets
├── MailExtension/                     # ★ 仅架构 C：NSExtensionPointIdentifier = com.apple.email.extension
│   ├── MailingoMailExtension.swift     # MEExtension 工厂
│   ├── TranslationSecurityHandler.swift# MEMessageSecurityHandler：横幅 + 自定义 VC
│   ├── TranslateBannerViewController.swift
│   └── Resources/Info.plist
├── Packages/MailingoKit/
│   ├── Sources/
│   │   ├── MailIntegration/            # 只依赖 Foundation
│   │   │   ├── CurrentMessageProvider.swift      (protocol + EmailMessage DTO)
│   │   │   ├── AppleMailAppleScriptProvider.swift
│   │   │   ├── MailSelectionScript.swift
│   │   │   └── AutomationPermission.swift
│   │   ├── EmailCore/                  # 只依赖 Foundation ★ 严禁 import AppKit
│   │   │   ├── MIME/  MIMEDecoder, MIMEPart, ContentID
│   │   │   ├── HTML/  HTMLTokenizer, SegmentExtractor, HTMLSplicer
│   │   │   └── Model/ TranslationSegment, EmailMessage, SegmentKind
│   │   ├── TranslationCore/            # 只依赖 Foundation + Translation
│   │   │   ├── TranslationEngine.swift           (protocol)
│   │   │   ├── AppleTranslationEngine.swift
│   │   │   ├── TranslationSessionHost.swift      (SwiftUI 桥)
│   │   │   ├── LanguageDetector.swift
│   │   │   └── FakeTranslationEngine.swift       (仅测试/预览)
│   │   ├── Cache/                      # 只依赖 Foundation
│   │   ├── Renderer/                   # AppKit + WebKit
│   │   ├── WindowIntegration/          # AppKit
│   │   ├── Infrastructure/             # Settings, Logging, PermissionManager
│   │   └── ExtensionBridge/            # ★ 仅架构 C：App Group 请求文件协议（App 与 appex 共用）
│   └── Tests/
│       ├── EmailCoreTests/  + Fixtures/Emails/*.eml, *.html
│       ├── TranslationCoreTests/
│       └── CacheTests/
└── docs/
```

**依赖方向（单向，不允许回头）**：

```
App ──> WindowIntegration, Renderer, Infrastructure
 │
 └──> MailIntegration ──> EmailCore <── TranslationCore ──> Cache
```

关键约束：
- `EmailCore` **绝不 import AppKit / SwiftUI**。可以加一个 CI 检查脚本 grep `import AppKit` 来守住。
- `TranslationCore` 不知道 `MailIntegration` 存在。
- 只有 `App/AppDependencies.swift` 做依赖注入组装，其他模块一律面向 protocol。

### 3.2 用 XcodeGen 而不是手改 xcodeproj

`project.yml` 描述 target / entitlement / Info.plist / package 依赖，`xcodegen generate` 产出工程。好处：`.xcodeproj` 不进版本控制（或进了也不用手工 merge），多人协作零冲突。

---

## 4. 核心链路详细设计

### 4.1 触发入口

| 入口 | 实现 | 权限 | 优先级 |
|---|---|---|---|
| **Mail 阅读窗格横幅 / 头部图标** ★ | Mail 扩展 `MEMessageSecurityHandler`（`MEDecodedMessage.banner` + `extensionViewControllerForMessageContext:`），点击后经 App Group 唤醒容器 App 显示侧栏 | **无** | **架构 C 主入口** |
| **全局快捷键 ⌥T** | `sindresorhus/KeyboardShortcuts`（底层 Carbon `RegisterEventHotKey`） | 无 | **架构 A 主入口 / 架构 C 兜底** |
| **菜单栏图标** | SwiftUI `MenuBarExtra` | 无 | V1（设置 + 手动触发 + 退出） |
| Services 菜单 | `NSServices` + `NSApp.servicesProvider` | 无 | V1.1（注意：Mail 的 Services 只传**选中的文本**，不传整封邮件，所以只能做"翻译选中文字"，价值有限） |
| App Intents | `AppIntent` + `AppShortcutsProvider` | 无 | V1.1（可被「快捷指令」/Spotlight 调用） |
| Mail 工具栏按钮 | ❌ 公开 API 不可实现（Message Security 的 UI 钩子只能产出横幅/头部图标，不能往工具栏塞控件） | — | — |

> 「Mail 内 Translate 按钮」在架构 C 下的**实际形态**：邮件顶部一条横幅（标题 + 「翻译」主操作按钮），以及邮件头部的一个扩展图标。详见 §2.5。

> 主窗口关闭后 App 仍驻留（`MenuBarExtra` + `LSUIElement` 可选）。建议 V1 用**常规 App + 菜单栏项**，不要一上来就 `LSUIElement`（无 Dock 图标会让用户找不到 App）。

### 4.2 CurrentMessageProvider

严格按 PRODUCT.md §4 的接口，但补上必要的元数据与能力查询：

```swift
public struct EmailMessage: Sendable {
    public let messageID: String          // Mail 的 message id（跨重启不稳定，仅作元数据）
    public let internetMessageID: String? // Message-ID 头，用于缓存 key
    public let subject: String
    public let sender: String
    public let dateReceived: Date?
    public let rawSource: Data            // 原始 RFC822，管线的唯一输入
}

public protocol CurrentMessageProvider: Sendable {
    func currentMessage() async throws -> EmailMessage
    func currentSelection() async throws -> SelectionSnapshot  // 用于判断"该不该刷新"
}
```

**实现 1（架构 A）：`AppleMailAppleScriptProvider`** —— 主动拉取，需 Automation 权限。

脚本（`MailSelectionScript.swift` 里以常量保存，便于随 Mail 升级而修改）：

```applescript
with timeout of 30 seconds
  tell application "Mail"
    set theViewers to message viewers
    if (count of theViewers) is 0 then error "NO_VIEWER"
    set theSel to selected messages of item 1 of theViewers
    if (count of theSel) is 0 then error "NO_SELECTION"
    set m to item 1 of theSel
    set theID to (id of m) as text
    set theMsgID to (message id of m) as text
    set theSubj to (subject of m) as text
    set theSender to (sender of m) as text
    set theSource to (source of m) as text
    return {theID, theMsgID, theSubj, theSender, theSource}
  end tell
end timeout
```

**必须注意的工程细节（都是真实的坑）：**

1. **Apple Event 调用是阻塞且不可取消的**，而且 Mail 弹模态 sheet 时会挂住。
   → 跑在专用串行队列/`Thread` 上，绝不占用 MainActor；`async` 包装 + 看门狗超时（脚本内 `with timeout` + 外层 `Task` 超时双保险）。
2. **`NSAppleScript` 非线程安全且编译慢** → 首次编译后缓存 `NSAppleScript` 实例（`isCompiled`），只在专用队列上 `executeAndReturnError`。
3. **大邮件**：`source` 可能几 MB。返回给 Swift 的是字符串，注意用 `Data` 边界（`NSString` → UTF-8）。若实测有截断/性能问题，退路是**原始 Apple Event**（`kAECoreSuite`/`kAEGetData` + `raso` 属性码）直接取 `typeFileURL`/`typeData` 避免字符串转换。列为 Spike 1 的验证项。
4. **错误态要覆盖**：Mail 未运行（自动 `NSWorkspace.openApplication` 拉起）、无阅读窗口、未选中邮件、多选、正文未下载（`source` 拿不到）、授权被拒。
5. **用 `AEDeterminePermissionToAutomateTarget`（`askUserIfNeeded: false`）先探测**，不要靠"发一次再看报错"来驱动权限引导 —— 这样能在用户没授权时先弹自己的说明卡片，再引导去系统设置。

> 关于 `ScriptingBridge` vs `NSAppleScript`：SB 更快但属性访问同步阻塞且无法设 timeout；`NSAppleScript` 可读性好、能写 `with timeout`、便于随 Mail 变化迭代。**V1 选 `NSAppleScript`**，把它藏在 `CurrentMessageProvider` 后面，将来换 SB 或换 IMAP 都不影响上层。

**实现 2（架构 C）：`MailExtensionMessageProvider`** —— 被动接收，**零权限**。

不是"拉取"而是"被推送"：Mail 调用 appex 的
`decodedMessage(forMessageData data: Data) -> MEDecodedMessage?`，参数就是完整原始邮件。
appex 把 `data` 落盘到 App Group 容器（**不要走通知 payload**，几 MB 会超限），再唤醒容器 App；
容器 App 侧的 `MailExtensionMessageProvider` 从这个共享目录读出 `EmailMessage`。

因此 `CurrentMessageProvider` 的两个实现分别对应"主动拉"与"被动推"。为了让上层只写一套代码，
建议把接口补一个事件源语义：

```swift
public protocol CurrentMessageSource: Sendable {
    /// 每次"用户请求翻译当前邮件"产出一个值。
    /// 架构 A：轮询/按需拉取；架构 C：等待 appex 投递。
    var requests: AsyncStream<EmailMessage> { get }
}
```

`AppleMailAppleScriptProvider` 与 `MailExtensionMessageProvider` 都实现它，
`⌥T` 与 Mail 内横幅两个入口最终汇入**同一条** `TranslationPipeline`。

**战略后手**：`CurrentMessageProvider` 这个抽象的真正价值是 **IMAP 直连 provider**（用户授权自己的邮箱，直接按 UID 取信）。它完全不依赖 Apple Mail 和 Apple Events，可以做 Windows/iOS 版，也绕开"Mail 未来收紧脚本"的风险。V1 不做，但接口要留好。

### 4.3 MIME 解码

输入：`rawSource`（Data）→ 输出：`DecodedEmail { html: String?, plainText: String?, inlineParts: [ContentID: MIMEPartRef], attachments: [MIMEPartRef] }`

- **选择：Kitura/SwiftMail**（已确认，见 §11 D3）。用 `MIMEDecoding` protocol 包住，上层不认识它。
- 接入时必须验证（Spike S4 用真实 `.eml` fixture）：RFC 2047 encoded-word 主题/发件人解码、quoted-printable 软换行、嵌套 `multipart/*`、`multipart/related` 的 `Content-ID` 收集、以及 **GB18030 / GBK charset** 支持。
  → 若发现丢字节或 CID 解析不全，退回自研精简解码器（约 300–500 行，Foundation-only）；因为已被 protocol 隔离，替换成本很低。
- **charset**：以 `Content-Type` 的 `charset=` 为准，缺失时回退 `<meta charset>`，再缺失回退 UTF-8 + 启发式（`String(data:encoding:)` 探测）。中文邮件里 GB18030/GBK 很常见，务必测。
- **纯文本邮件**：转义 `& < >` 后用 `<p>`/`<br>` 包装成简单 HTML，走同一条 HTML 管线（PRODUCT.md §5 要求）。

### 4.4 HTML 保真管线 ★ 本方案的核心

PRODUCT.md §6 的要求是「HTML 是骨架，只翻译内容，不让模型重新生成整个 HTML」。**业界最常见的错误做法是"解析成 DOM → 改文本 → 序列化回去"** —— 任何序列化器都会重排属性顺序、补全/删除标签、改写实体、规范化空白，保真度必然受损。

**本方案采用「字节偏移切片（offset-preserving splice）」：**

```
raw HTML (String/Data)
   │
   ├─ 单遍 HTML Tokenizer（自研，状态机）
   │     · 维护 tag 栈 → 得到每个文本节点的上下文（heading / paragraph / tableCell / button / footer）
   │     · 跳过 <script> / <style> / <head> / 注释 / CDATA / DOCTYPE
   │     · 为每个文本节点记录 **原始字符串中的精确 Range**
   │
   ├─ SegmentExtractor → [TranslationSegment(id, range, sourceText(已解码实体), kind, context)]
   │     · 拆出 前导空白 / 正文 / 尾随空白（引擎会吃掉空白，必须保留）
   │     · 过滤：纯空白、纯数字/符号、纯 URL、超长（>2000 字符）、已是目标语言
   │
   ├─ TranslationEngine.translate(segments)   ← 只发文本，按 id 对账
   │
   └─ HTMLSplicer：把译文按 **逆序** 写回原字符串的原始 Range
         · 只替换文本，其余字节 100% 原样
         · 重新做 HTML 实体转义（& < > " 以及 nbsp → &nbsp;）
```

**这样能拿到什么保证：**
- `href` / `class` / `id` / `style` / `data-*` / DOM 层级 —— **物理上不可能被改动**（根本没碰那些字节）。
- 表格布局、CSS、Outlook 条件注释 `<!--[if mso]>`、`<style>` 里的媒体查询、tracking pixel —— 全部原样。
- 可以直接写一条强断言测试：**"把译文替换回原文后，非文本节点的字节序列必须完全一致"**。

**需要处理的细节：**

| 问题 | 处理 |
|---|---|
| 实体 | 翻译前 `&amp;`→`&`、`&#233;`→`é`、`&nbsp;`→U+00A0；翻译后按最小必要重新转义 |
| 空白 | 保留前导/尾随空白，不交给引擎 |
| `<title>` | 默认跳过（对邮件无意义） |
| `alt` / `title` / `placeholder` / `aria-label` / `value`(submit) | 作为可选的布尔开关，默认**开** `alt`/`title`（低风险、收益明显） |
| `<style>` 里的 `content:` | V1 不做 |
| 大小写/编码 | 全程在 `String` 上按 `Range<String.Index>` 操作，写回时统一 UTF-8 |

**渲染用的"可寻址"副本（独立于缓存产物）：**
为了支持**流式渐进翻译**（面板秒开、中文逐段填进去），渲染副本里给每个文本节点打上序号，用一段自注入 JS 维护 text node 索引：

```js
// 加载时走一遍 DOM，按与 Swift 完全相同的跳过规则收集文本节点
// 与 Swift 传进来的 sourceText 列表逐项比对：
//   一致 → 后续按 index 直接 node.nodeValue = 译文（零 DOM 结构改动）
//   不一致 → 放弃增量更新，整页 reload 已切片的最终 HTML（安全兜底）
```

比对 + 兜底这个设计很重要：它让"渐进更新"和"绝不破坏结构"两个目标同时成立。

### 4.5 TranslationCore

**协议**（相对 PRODUCT.md §7 做了必要强化：批量、进度、能力查询、稳定 id 用于缓存命名空间）：

```swift
public struct EngineAvailability: Sendable { public let canTranslate: Bool; public let needsDownload: Bool; public let reason: String? }

public protocol TranslationEngine: Sendable {
    var id: String { get }                 // "apple.translation.v1" —— 进缓存 key
    var displayName: String { get }
    func availability(source: Locale.Language?, target: Locale.Language) async -> EngineAvailability
    func prepare(source: Locale.Language?, target: Locale.Language) async throws
    func translate(_ segments: [TranslationSegment],
                   source: Locale.Language?, target: Locale.Language,
                   progress: @Sendable (_ done: Int, _ total: Int) -> Void) async throws -> [TranslatedSegment]
}
```

**`AppleTranslationEngine` + `TranslationSessionHost`（关键实现）**

因为 macOS 15 上 session 只能由 `.translationTask` 给（见 §0②），所以：

```swift
@MainActor
final class TranslationSessionHost {
    private var hostView: NSHostingView<TranslationTaskHostView>!
    private var sessionContinuation: CheckedContinuation<TranslationSession, Never>?

    // 用一个「透明的 1x1 子视图」挂在可见面板的视图层级里：
    //   · 必须在某个真实可见 window 的层级中，否则 onAppear 不触发、系统下载弹窗没有 parent
    //   · 通过 configuration.version 递增 + invalidate() 来"重新触发" translationTask
}
```

要点：
1. **宿主视图必须挂在真实可见窗口的层级里**。因此把它作为侧栏面板内容的 1x1 子视图（而不是一个独立的离屏 window）—— 这样语言包下载确认 sheet 才有正确的父窗口。
2. `.translationTask` 的闭包是 `async` 且在主 actor；`TranslationSession` **不是 `Sendable`** → session 严格限制在 MainActor 上使用。HTML/MIME 的重活全在后台 actor，只有"发文本/收文本"这一步回主 actor。
3. **串行化**：同一时刻只允许一个 batch 在飞（session 不支持并发调用）。用一个 `actor` 排队。
4. **重触发**：`.translationTask(configuration, action:)` 只在 configuration 变化时重跑。要连续处理多封邮件，就 `configuration.invalidate()` 并递增 `version`，让 SwiftUI 重新调用 action 拿到新 session。这是这套 API 最容易踩的坑。
5. **分批**：`translations(from:)` 每批控制在 **25–50 段**（具体上限与耗时需要 Spike 2 实测），批间可上报进度、可 `Task.checkCancellation()`。
6. **流式**：也可用 `translate(batch:)` 返回的 `AsyncSequence` 边出边渲染；建议"分批 + 批内流式"混合，UI 最先有反馈。
7. **macOS 26 优化路径**：`if #available(macOS 26)` 时改用 `TranslationSession(installedSource:target:)` 直接构造 + `isReady` / `canRequestDownloads` / `cancel()`，不再需要隐藏宿主。用 `#available` 分支，两套并存，部署目标仍是 macOS 15。
8. **源语言检测**：用 `NLLanguageRecognizer`（NaturalLanguage，本地、免费、无权限）对前 ~500 字符做检测，再拿 `LanguageAvailability().status(from:to:)` 判断是否 `.installed`。若 `source == target` 直接跳过。
9. **错误映射**：`TranslationError.nothingToTranslate`（视为空串成功）、`unableToIdentifyLanguage`（回退让引擎自己检测）、`unsupportedLanguagePairing`（明确报错给 UI）。
10. **`FakeTranslationEngine`**（回显 / 大写 / 固定替换）必须随 V1 一起写 —— 它是整个管线可测、CI 可跑、UI 可预览的前提。

> 注意：Apple 端上翻译对营销文案/专业术语质量一般。`TranslationEngine.id` 进缓存 key 的设计，正是为将来切 DeepSeek/DeepL 时"旧缓存自动失效、互不污染"服务。

### 4.6 Renderer（WKWebView）

```swift
final class EmailWebView: NSViewRepresentable / NSView
```

- **安全默认值（对齐 Mail 的行为）**：
  - 渲染前**剥离全部 `<script>`、`<iframe>`、`on*=` 属性**（tokenizer 已经识别了标签边界，这一步几乎零成本）。
  - **默认阻断远程图片**，用 `WKContentRuleList` 拦 `http(s)` 子资源；面板顶部显示"载入远程图片"按钮，点击后临时放行并 reload。
- **CID 内联图**：注册自定义 scheme handler（如 `mailingo-cid://`），把 `src="cid:XYZ"` 改写成 `mailingo-cid://XYZ` 并从 MIME 部分提供字节。
  → 这个改写**只发生在渲染副本上**，缓存里的译文 HTML 保持原样。
- **链接**：`WKNavigationDelegate` 拦截导航，一律 `NSWorkspace.shared.open` 到默认浏览器，绝不在面板内导航。
- **`baseURL` 传 nil**，避免相对路径对外发请求。
- 滚动位置/宽度在切换邮件间保持。

### 4.7 WindowIntegration

```swift
protocol MailWindowObserver: Sendable {
    var frameStream: AsyncStream<MailWindowState> { get }   // .visible(NSRect) / .hidden / .mailNotRunning
}
```

- **`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` + PID 匹配**（不用 ownerName，见 §0③）。
- 选窗口的启发式：同 PID 中 `kCGWindowLayer == 0` 且面积最大者（数组本身就是前到后顺序，取第一个满足的即最前窗口）。窗口无标题可读，所以**不能**靠标题区分"主窗口/偏好设置"。
- **轮询节奏**：只在 Mail 是 frontmost（`NSWorkspace.didActivateApplicationNotification`）时启动，10 Hz；Mail 失焦即停。26 个窗口的枚举成本可忽略，但不能 24 小时空转。
- **隐藏/最小化同步**：窗口从 `onScreenOnly` 列表消失 → 面板 `orderOut`。配合 `NSWorkspace.didHideApplicationNotification`。
- **面板配置**：
  ```swift
  NSPanel(contentRect:styleMask: [.titled, .fullSizeContentView, .resizable, .utilityWindow, .nonactivatingPanel],
          backing: .buffered, defer: false)
  panel.titlebarAppearsTransparent = true
  panel.titleVisibility = .hidden
  panel.isFloatingPanel = false          // 不要常驻置顶
  panel.level = .normal                  // 需要时用 .floating（见下）
  panel.hidesOnDeactivate = false
  panel.becomesKeyOnlyIfNeeded = true    // 点侧栏不抢 Mail 的焦点
  panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  ```
- **摆放算法**：`x = min(mailFrame.maxX, screenVisibleFrame.maxX - width)`，`y/height` 对齐 `mailFrame`；宽度持久化到 `UserDefaults`，最小 320 / 最大 720。
- **全屏 Mail**：`.canJoinAllSpaces + .fullScreenAuxiliary` 通常能让面板出现在别的 App 的全屏 Space 上，但**这一条必须 Spike 3 实测**（跨 App 全屏行为在不同 macOS 版本上不一致）。兜底方案：检测到 Mail 进入全屏时降级为"面板贴在屏幕右侧 + 提示"或暂时隐藏。
- **模式 B（V1.1）**：`AXUIElement` 读/写 Mail 窗口的 `kAXSizeAttribute` / `kAXPositionAttribute`，先给 Mail 让位再放面板，关闭时还原。做成设置项「让 Mail 让出空间」。

### 4.8 Cache

```swift
key = SHA256( rawSourceBytes ‖ targetLanguage ‖ engine.id ‖ pipelineVersion )
```

- PRODUCT.md §11 建议含 `Message-ID`。**要注意 `Message-ID` 单独做 key 不安全**（同一 ID 内容可能变/重复），所以以**内容哈希为主键**，`Message-ID`/`message id`/`subject` 只作为元数据存下来做调试与统计。
- `pipelineVersion` 很重要：切片算法或实体处理一旦修改，旧缓存必须失效。
- 存储：`~/Library/Application Support/Mailingo/Cache/<key>.html` + `<key>.json`（segments + 元数据）。L1 是内存 `NSCache`，L2 是磁盘。
- 淘汰：按 mtime 的 LRU + 总容量上限（默认 200 MB）；原子写入（写临时文件 + `replaceItemAt`）。
- 缓存内容：**译文 HTML、segments、源语言、引擎 id、时间戳**；V2 加译文图片。
- 另外单独缓存 `rawSource`（按 Mail message id，短 TTL）—— `source` 这个 Apple Event 不便宜，同一封邮件反复触发时省一次往返。

**扩展性要求**：`CacheStore` 是 `actor`，接口只认 `Data`/`Codable`，不知道任何模型/引擎细节（PRODUCT.md §13）。

---

## 5. 权限、签名与分发 ★ 必须尽早决定

### 5.1 权限矩阵

| 能力 | 需要什么 | V1 是否必需 |
|---|---|---|
| **（架构 C）读取当前邮件** | **无权限** —— Mail 通过 `decodedMessage(forMessageData:)` 主动把原始 MIME 交给扩展 | 架构 C 下**不需要 Automation** ★ |
| **（架构 A）读取当前邮件** | **Automation / Apple Events → Mail** + Info.plist `NSAppleEventsUsageDescription` + Hardened Runtime `com.apple.security.automation.apple-events` | 架构 A 下必需 |
| 跟随 Mail 窗口 | 无（CGWindowList） | ✅ 需要，但零成本 |
| 让 Mail 让出空间（模式 B） | **Accessibility** | ❌ V1.1 可选 |
| 全局快捷键 ⌥T | 无（Carbon） | — |
| 加载远程图片 | 无（非沙盒直连；沙盒下需 `network.client`） | — |
| 语言包下载 | 无（系统负责） | — |

> ★ **架构 C 最大的隐性收益**：完全绕开 Automation / Apple Events。权限面从"能读你所有邮件"降到"Mail 递给扩展的那一封"，权限模型明显更干净，也更容易向用户解释。

✅ 全程**不需要 Full Disk Access**，**不读 `~/Library/Mail/`** —— 与 PRODUCT.md §12 完全一致。

### 5.2 沙盒 vs 分发的硬冲突

**先澄清一个容易搞混的点（S0 实测踩到）：沙盒是"按 target"决定的，不是整个产品一刀切。**

| Target | 沙盒 | 原因 |
|---|---|---|
| **Mail 扩展（appex）** | ✅ **必须 YES** | macOS 硬性要求。不带 `com.apple.security.app-sandbox`，`pkd` 不会注册它：`pluginkit` 查不到、Mail 扩展面板为空。Xcode 的 Mail Extension 模板默认也是 YES |
| **容器 App** | ❌ **必须 NO** | App Sandbox 下 Accessibility API 不可用 → 模式 B（让 Mail 让出空间）直接做不到 |

两者不冲突：沙盒的是 appex，不是 App。

- **沙盒下给 Mail 发 Apple Event** 需要 `com.apple.security.automation.apple-events`；若要指定目标 App，则需 `com.apple.security.temporary-exception.apple-events` —— 这是**临时例外**，Mac App Store 审核要单独申请且经常被拒。（架构 C 走扩展拿 MIME，本来就绕开了这项权限）
- **appex 与容器 App 的数据交接**：appex 沙盒后只能写自己的容器
  （`~/Library/Containers/<appex-id>/Data/…`），而容器 App 非沙盒、能直接读该绝对路径 —— 这条路径 S0 已经跑通。
  更规范的做法是 **App Group**，但它需要带 app group entitlement 的 provisioning profile；
  当前手动签名无 profile，所以 V1 先用"容器路径"方案，等要上架/做多点同步时再切 App Group。

> **结论：V1 走 Developer ID 直分发 + 公证（notarization）。容器 App 不开沙盒，appex 必须开沙盒。** 这样 Automation / Accessibility 都能用，扩展也能被 Mail 正常加载。
> 如果将来一定要上 MAS，就只能是"沙盒版 = 阉割版（需用户手动授予临时例外）"，两条发行通道功能不一致 —— 建议**不要**为此牺牲 V1 体验。

### 5.3 签名相关的开发期陷阱

- **TCC 授权绑定代码签名**。开发期如果每次重建都变签名，用户会被反复弹窗。
  → 用固定的自签名证书或真实 Developer ID，`CODE_SIGN_IDENTITY` 保持一致；重置用 `tccutil reset AppleEvents com.yourorg.mailingo`。
- 首次 ⌥T → 系统弹「Mailingo 想要控制"邮件"」→ 允许；（若用过模式 B）再弹「辅助功能」。
- 引导页要写清楚**为什么**需要这两项权限，并提供直达系统设置的按钮。

### 5.4 菜单栏信息架构

菜单栏图标（`MenuBarExtra`）承载：翻译当前邮件 ⌥T / 目标语言 / 载入远程图片 / 权限状态 / 清空缓存 / 设置 / 关于 / 退出。

---

## 6. 测试策略

这是"最佳实践"里最容易被跳过、但对本项目最关键的一块。

| 层级 | 内容 |
|---|---|
| **HTML 保真（最高优先级）** | Fixture 语料：营销邮件、Newsletter、`<table>` 布局、Outlook 条件注释、内联 `<style>`、CID 图、GB18030 邮件、只有纯文本的邮件。断言：① **非文本节点字节级完全一致**；② 标签序列（走一遍 tokenizer 的结果）前后一致；③ 只有被选中的文本节点变化。 |
| **属性测试** | 任取一段无文本节点的 HTML，`splice(extract(x)) == x` 必须字节相等。 |
| **MIME** | `.eml` fixture：base64 / QP / `multipart/alternative` / `related` / 嵌套 multipart / RFC 2047 编码的主题与发件人 / 边界情况（QP 软换行、缺 charset）。 |
| **引擎** | `FakeTranslationEngine` 让整条管线无需 Apple Translation、无需网络即可测；`AppleTranslationEngine` 单独做集成测试（标记为需要语言包，CI 中可跳过）。 |
| **窗口跟随** | `MailWindowObserver` 的几何摆放算法做成**纯函数** `panelFrame(for mailFrame:screenFrame:width:)` —— 可直接单测，不用真的开 Mail。 |
| **缓存** | key 稳定性、`pipelineVersion` 变更后失效、LRU 淘汰、损坏文件的容错。 |
| **UI 快照** | 可选：WKWebView 渲染截图对比（用 `SCScreenshotManager` 或 `takeSnapshot`）。开销大，V1 用人工比对代替。 |
| **并发** | Swift 6 严格并发打开（`-strict-concurrency=complete`），把 data race 变成编译期错误。 |

---

## 7. 技术选型与依赖

| 用途 | 选择 | 理由 |
|---|---|---|
| 工程生成 | **XcodeGen** (`project.yml`) | 工程文件可 review、无 merge 冲突 |
| HTML 解析 | **自研单遍 Tokenizer** | 要的是"字节级保真"，不是 DOM 序列化；SwiftSoup 序列化必然改字节 |
| DOM 校验（仅测试） | SwiftSoup | 测试里对比结构是否一致，**不进产品运行时** |
| MIME | **Kitura/SwiftMail**（被 `MIMEDecoding` protocol 包住） | 已确认；替换成本低 |
| 全局快捷键 | `sindresorhus/KeyboardShortcuts` | 成熟，Carbon 实现，无权限 |
| 日志 | `os.Logger`（unified logging） | 零依赖，`log stream` 可实时看 |
| 缓存 | 自研 `actor` + FileManager（备选 GRDB） | V1 文件系统足够；要复杂查询再上 GRDB |
| 设置 | `UserDefaults` + `@Observable`；未来 API Key → **Keychain** | 密钥绝不进 UserDefaults |
| 状态管理 | Swift 5.9+ `@Observable`（Observation） | 原生，无第三方 |
| 图片翻译（V2） | 先留 `ImageTranslating` protocol 空位 | V1 明确不做 |

**依赖总数刻意压到 1 个运行时依赖**（KeyboardShortcuts）。其余全部系统框架。

---

## 8. Spike 计划：先验证，再开发

在写产品代码之前，用 2–3 天做 4 个 spike。**任何一条不过，方案要改，而不是硬着头皮写。**

| # | 目标 | 通过标准 | 风险等级 |
|---|---|---|---|
| **S0** ★ | **Mail 扩展探针**：最小 Mail Extension（`MessageSecurityHandler`）返回带 `banner` 的 `MEDecodedMessage`，观察对**普通未加密邮件**的行为 | `decodedMessageForMessageData:` 对普通邮件**确实被调用**（打日志确认）；返回非 nil 后**横幅真的显示**；点横幅能呈现自定义 `MEExtensionViewController`；`data` 参数确实是完整原始 MIME | 🔴 **最高（决定架构 C 是否成立）** |
| **S1** | 最小 .app：正确 Info.plist + `NSAppleEventsUsageDescription` + 稳定签名，从 Mail 取 `selected messages[0].source` | TCC 弹窗正常出现；**授权在重建后仍有效**；大邮件（>2 MB）不截断、耗时可接受；正文未下载时有明确错误 | 🔴 高（架构 A 的前提） |
| **S2** | 隐藏 SwiftUI `.translationTask` 宿主（挂在 1x1 子视图上）驱动 100 段批量翻译 | 无需可见 SwiftUI 界面即可拿到 session；语言包未安装时的系统下载弹窗能正常出现；测出**每批安全上限**与端到端耗时 | 🔴 高 |
| **S3** | CGWindowList 跟随 Mail：移动 / 缩放 / 最小化 / 隐藏 / **全屏 Space** | 几何跟随稳定无抖动；全屏场景结论明确（可行 or 需降级方案）；CPU 占用可接受 | 🟡 中 |
| **S4** | HTML 保真 harness：20 封真实 HTML 邮件跑 抽取→假翻译→切片 | **非文本字节 100% 一致**；WKWebView 里与原邮件渲染视觉一致 | 🟡 中 |
| **S5** | Mail 扩展 → 容器 App 的 App Group 握手（架构 C 时） | 几 MB MIME 走文件、通知只传路径；容器 App 能被可靠唤醒；扩展进程无长时间阻塞 | 🟡 中 |

> **S0 决定架构取舍**：通过 → 走架构 C（Mail 内入口 + 零 Automation 权限）；不通过 → 退回架构 A（⌥T + Apple Events）。
> **S1 / S2 是 go/no-go**（架构 A 读邮件、翻译引擎）。S1 失败 → 整个"读 Mail 当前邮件"的路线要重新考虑（转向 IMAP provider）。S2 失败 → 翻译引擎要换成在线 API（那就影响"零成本、无需 Key"的 V1 定位）。

---

## 9. 里程碑（单人估算）

| 里程碑 | 内容 | 工作量 |
|---|---|---|
| **M0** | Spike **S0**（架构决策）+ S1–S5 + 技术决策定稿 | 3–4 天 |
| **M1** | 骨架：XcodeGen 工程、SPM 模块、`AppDependencies` 组装、菜单栏、⌥T、日志、测试基建 | 2 天 |
| **M2** | MailIntegration：脚本 provider、权限探测与引导、全部错误态 | 1.5 天 |
| **M3** | EmailCore：MIME 解码、Tokenizer、SegmentExtractor、HTMLSplicer、纯文本路径 + 黄金测试 | 4 天 |
| **M4** | TranslationCore：`TranslationSessionHost`、Apple 引擎、分批/流式、语言检测、`FakeTranslationEngine` | 3 天 |
| **M5** | Renderer：WKWebView、CID scheme handler、脚本剥离、远程图阻断、渐进更新（含 JS 比对兜底） | 2.5 天 |
| **M6** | WindowIntegration：跟随、显隐同步、宽度持久化、多 Space/全屏 | 2 天 |
| **M7** | Cache：key、LRU、失效、rawSource 缓存 | 1 天 |
| **M8** | 打磨：引导页、错误 UX、中英文本地化、关于、公证、README | 2 天 |
| **M9**（仅架构 C） | Mail 扩展 target：`MEMessageSecurityHandler` + 横幅 + 自定义 ViewController + App Group 握手 | 3–4 天 |
| | **合计** | **≈ 20–27 个工作日**（取决于架构 A / C） |

排序原则：**M0 → M3（纯逻辑、可测、无权限依赖）→ M2/M4 → M5/M6 → M8**。M3 其实可以更早并行推进，因为它零外部依赖。

---

## 10. 风险登记

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | Mail 工具栏无法加按钮 | 入口形态与 PRODUCT.md 原意不同 | 已修正于 §0①；改用阅读窗格横幅 + 头部图标（架构 C） |
| R11 | Message Security 扩展点被 Apple 收紧 / 判定为滥用 | 架构 C 失效 | 架构 A 始终保留为可独立交付的降级路径；两架构共用同一条翻译管线 |
| R12 | 对普通邮件返回非 nil `MEDecodedMessage` 导致 Mail 显示错误的安全状态 | 观感/信任受损 | Spike S0 中观察 Mail 的安全 UI 表现；必要时改为"仅横幅、不声明签名信息"的最小返回 |
| R2 | Apple Events 被未来 macOS 收紧，或 Mail 改脚本字典 | 核心链路断裂 | `CurrentMessageProvider` 抽象 + IMAP provider 作为后手 |
| R3 | `source` 对未下载邮件不可用 / 大邮件性能差 | 部分邮件翻不了 | 明确错误提示 + 引导在 Mail 里打开一次；必要时改用原始 Apple Event 取 data |
| R4 | Apple 端上翻译质量一般 | 观感 | 引擎可插拔，后续上 DeepSeek/DeepL |
| R5 | `translations(from:)` 的批量上限/限流未知 | 长邮件失败 | Spike 2 实测；分批 + 重试 + 退避 |
| R6 | 跨 App 全屏 Space 上浮窗不可见 | 全屏场景不可用 | Spike 3 确认；降级为"贴屏右侧/隐藏" |
| R7 | 开发期 TCC 反复弹窗 | 开发体验差 | 固定签名身份；`tccutil reset` |
| R8 | 非沙盒 → 无法上 MAS | 分发渠道 | V1 明确不上 MAS |
| R9 | 渐进更新的 JS 索引与 Swift 段序漂移 | 译文错位 | 加载时逐项比对 + 不一致就整页 reload 兜底 |
| R10 | 渲染不可信邮件 HTML | 安全 | 剥离 script/iframe/on*，默认阻断远程图片 |

---

## 11. 开放决策

### 已确认

| # | 决策 | 结论 |
|---|---|---|
| D1 | 侧栏摆放 | **模式 A 为 V1**，V1.1 再加模式 B（让 Mail 让出空间，需 Accessibility） |
| D2 | 分发渠道 | **Developer ID 直分发 + 公证，不开沙盒**（MAS 不作为 V1 目标） |
| D3 | MIME 解析 | **引入 Kitura/SwiftMail**，用 `MIMEDecoding` protocol 包住 |

> ⚠️ D3 的一个提醒：SwiftMail 面向"构造/发送"场景，其中文/GB18030 等 charset 与 `multipart/related` 内联图（CID）的支持需要在 Spike S4 里用真实 `.eml` fixture 先验一遍。若发现丢字节或 CID 解析不全，因为已被 protocol 包住，退回自研的成本很低。

### 已由 S0 实测确定

| # | 决策 | 结论 |
|---|---|---|
| D4 | **入口架构** | ✅ **架构 C**。2026-09-23 S0 四问全过：普通未加密邮件确实会调用 `decodedMessage(forMessageData:)`，横幅渲染并可点击，能拿到完整原始 MIME。详见 `docs/S0-PROBE.md` |
| D5 | 快捷键兜底 | ✅ 仍然做 `⌥T`。扩展入口与快捷键共用同一条 `TranslationPipeline`，边际成本很低；且用户可能不启用扩展 |
| D6 | App 名 | ✅ **Mailingo** |

**S0 带来的设计修正（已并入本文相关章节）**：
- 容器 App 非沙盒、**appex 必须沙盒**（§5.2）—— 沙盒按 target 分开决定。
- Mail 递来的 MIME 是 **LF 行尾**（已归一化），但解析必须同时支持 LF/CRLF。
- **头部区可能超过 8KB**（实测 152 行、单行最长 970 字符），不能只看前 8KB。
- 同一封邮件 `decodedMessage` 会**被调用多次**（实测 3 次）→ §4.8 缓存是刚需。

---

## 参考资料

- Apple Developer — [Translation framework](https://developer.apple.com/documentation/translation/)、[TranslationSession](https://developer.apple.com/documentation/translation/translationsession)、[`translationTask(_:action:)`](https://developer.apple.com/documentation/swiftui/view/translationtask(_:action:))
- Apple Developer — [MEExtension](https://developer.apple.com/documentation/mailkit/meextension)、[MEMessageActionHandler](https://developer.apple.com/documentation/mailkit/memessageactionhandler)、[MEMessageSecurityHandler](https://developer.apple.com/documentation/mailkit/memessagesecurityhandler)、[MEMessageDecoder](https://developer.apple.com/documentation/mailkit/memessagedecoder)
- Apple Developer — [Build Mail app extensions (WWDC21 10168)](https://developer.apple.com/videos/play/wwdc2021/10168/)
- 参考实现 — [Suboptimierer/MailAppExtensionExample](https://github.com/Suboptimierer/MailAppExtensionExample)（写信窗口附件提醒；其 README 记录了两个 MailKit bug：`allowMessageSendForSession` 从不被调用、`session.mailMessage.rawData` 恒为 nil，并注明"希望 Mail 扩展能获得 Safari 扩展那样的能力"——即当时并无通用 UI 注入能力）
- Apple Developer — [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:))
- 本机核实（macOS 26.0 SDK）：
  - `MailKit.framework/Headers/`：`MEExtension.h`、`MEComposeSession.h`（`viewControllerForSession:`）、`MEMessageSecurityHandler.h`（`extensionViewControllerForMessageContext:` / `primaryActionClickedForMessageContext:`）、`MEMessageDecoder.h`、`MEDecodedMessage.h`（`banner` / `context`）、`MEMessageSecurityInformation.h`
  - `Translation.framework/.../Translation.swiftinterface`、`_Translation_SwiftUI.framework/.../swiftinterface`
  - `/System/Applications/Mail.app/Contents/Resources/Mail.sdef`
  - Xcode 模板 `Platforms/MacOSX.platform/.../Mail Extension.xctemplate`（`NSExtensionPointIdentifier = com.apple.email.extension`，仅 4 个 capability，**无 entitlements 文件**）
- 真机实测：`CGWindowListCopyWindowInfo` 在未授予屏幕录制权限时仍返回 bounds/PID（仅 `kCGWindowName` 为 nil），且 `kCGWindowOwnerName` 受本地化影响（中文系统下 Mail 显示为「邮件」）；shell 直接 `osascript` 控制 Mail 返回 `-10004`。
- 说明：本会话的 `web_search` 端点配置异常，无法联网检索，故上述结论以**本机 SDK 头文件与真机实验**为准；`decodedMessageForMessageData:` 对普通邮件是否被调用属唯一未能离线确证的点，已列为 Spike S0。
