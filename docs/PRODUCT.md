# Apple Mail 翻译助手

## 1. 产品定位

开发一个原生 macOS 应用，为 Apple Mail 提供“一键全文翻译”。

核心目标：

> 用户在 Apple Mail 中打开一封外语邮件，点击 Mail 内的「Translate」按钮，右侧立即出现一份完整的中文邮件。

不是简单翻译文字，而是：

> 生成当前邮件的“中文版镜像”。

---

## 2. 核心交互

主要流程：

```text
打开 Apple Mail
      ↓
打开一封外语邮件
      ↓
点击 Mail 内的「Translate」按钮
      ↓
读取当前选中的邮件
      ↓
翻译邮件
      ↓
右侧弹出吸附式 Sidebar
      ↓
显示完整中文版邮件
```

主要入口：

```text
① Apple Mail 内 Translate 按钮
② 快捷键，例如 ⌥T
③ 菜单栏 App 作为设置和备用入口
```

V1 不要求自动翻译所有邮件。

---

## 3. Sidebar 设计

翻译结果使用独立的 macOS 原生窗口 / NSPanel。

视觉上吸附在 Apple Mail 右侧：

```text
┌────────────── Apple Mail ──────────────┐┌──── 中文翻译 ────┐
│                                       ││                  │
│          Original Email               ││   中文版邮件     │
│                                       ││                  │
│                                       ││                  │
└───────────────────────────────────────┘└──────────────────┘
```

要求：

- UI 风格尽量与 Apple Mail 一致
- 使用 SwiftUI / AppKit 原生组件
- Apple Mail 移动时 Sidebar 跟随
- Apple Mail Resize 时 Sidebar 同步调整
- Apple Mail 最小化 / 隐藏时 Sidebar 同步隐藏
- Sidebar 可单独关闭
- Sidebar 宽度可调整

右侧只显示中文版邮件。

不需要：

- 原文模式
- 双语模式
- 原文 / 译文切换

左侧 Apple Mail 已经是原文。

---

## 4. 当前邮件获取

不要把具体实现方式写死。

统一定义：

```swift
protocol CurrentMessageProvider {
    func currentMessage() async throws -> EmailMessage
}
```

目标：

> 用户点击 Translate 时，获取 Apple Mail 当前正在查看 / 选中的邮件。

候选实现：

```text
MailKit
Apple Events
ScriptingBridge
其他官方或稳定的 macOS 接口
```

优先选择：

- 稳定
- 权限最少
- 不依赖 Apple Mail 私有 API
- 不直接读取 ~/Library/Mail 数据库

Translate 按钮只负责触发翻译流程，不直接承担邮件解析逻辑。

---

## 5. 邮件处理

获取完整邮件后：

```text
Raw Email / MIME
       ↓
MIME Parser
       ↓
优先获取 text/html
       ↓
HTML DOM Parser
       ↓
提取可翻译内容
```

需要支持：

```text
text/html
text/plain
multipart/*
CID 图片
远程图片
附件
```

如果邮件只有纯文本，则生成简单 HTML。

---

## 6. 翻译原则

核心原则：

> HTML 是骨架，只翻译内容，不让模型重新生成整个 HTML。

流程：

```text
Original HTML
      ↓
解析 DOM
      ↓
提取 Text Nodes
      ↓
Translation Engine
      ↓
将译文替换回原 DOM
      ↓
Translated HTML
```

必须尽量保留：

- HTML 标签
- CSS
- 表格
- 列表
- 粗体
- 链接
- 按钮
- 图片位置
- 原始布局

原则上不修改：

```text
href
class
id
style
data-*
DOM hierarchy
```

---

## 7. 翻译引擎

翻译层设计为可插拔。

统一接口：

```swift
protocol TranslationEngine {
    func translate(
        segments: [TranslationSegment],
        sourceLanguage: String?,
        targetLanguage: String
    ) async throws -> [TranslatedSegment]
}
```

### V1

默认：

```text
Apple Translation Framework
```

原因：

- 原生 macOS 能力
- 无需 API Key
- 无额外 API 成本
- 延迟低
- 适合第一版

默认目标语言：

```text
简体中文
```

自动检测源语言。

### 后续

可以增加：

```text
DeepSeek
OpenAI
DeepL
其他 LLM
```

更换 Translation Engine 不应影响：

- Mail 获取
- HTML 解析
- Sidebar
- 缓存

---

## 8. Translation Segment

不要直接把整份 HTML 当作一个字符串翻译。

建议数据结构：

```text
TranslationSegment

id
type
sourceText
translatedText
htmlNodeID
context
```

type 示例：

```text
heading
paragraph
button
tableCell
footer
```

未来接入 DeepSeek 等 LLM 时，可以提供整封邮件上下文，提高术语和语义一致性。

---

## 9. 图片处理

V1：

> 保留所有原始图片，不做图片翻译。

后续版本再增加图片翻译。

图片分为：

```text
普通图片
→ Logo / 照片 / 商品图
→ 不处理

带文字图片
→ Banner / 海报 / 信息图
→ 图片翻译 API

Tracking / Icon
→ 不处理
```

不要对所有图片无脑调用图片翻译 API。

---

## 10. 渲染

最终中文版邮件使用：

```text
WKWebView
```

进行 HTML 渲染。

目标：

```text
原始邮件                 中文邮件

Logo                     Logo
HTML Layout              Same Layout
English Title            中文标题
English Text             中文正文
Images                   Images
Buttons                  中文按钮
Links                    Same Links
```

---

## 11. 缓存

同一封邮件不要重复翻译。

Cache Key 建议包含：

```text
Message-ID
邮件内容 Hash
目标语言
Translation Engine
```

缓存：

```text
Translated HTML
Translation Segments
后续的 Translated Images
```

再次点击 Translate 时优先读取缓存。

---

## 12. 权限原则

只申请真正需要的权限。

可能涉及：

```text
Mail Extension
Automation / Apple Events
Accessibility
Network Client
```

用途：

```text
Mail Integration
→ Mail Extension

读取当前邮件
→ Automation / Mail API

跟随 Mail 窗口
→ Accessibility

DeepSeek 等在线模型
→ Network
```

禁止为了方便申请：

```text
Full Disk Access
```

禁止直接读取：

```text
~/Library/Mail/
```

---

## 13. 工程原则

代码必须模块化，避免形成单个巨大 Controller。

建议：

```text
MailTranslate
│
├── App
│
├── MailIntegration
│   ├── CurrentMessageProvider
│   └── AppleMailAdapter
│
├── EmailCore
│   ├── MIMEParser
│   ├── HTMLParser
│   ├── SegmentExtractor
│   └── HTMLRebuilder
│
├── TranslationCore
│   ├── TranslationEngine
│   ├── AppleTranslationEngine
│   └── DeepSeekTranslationEngine
│
├── Renderer
│   └── EmailWebView
│
├── WindowIntegration
│   ├── MailWindowObserver
│   └── TranslationPanelController
│
├── Cache
│
└── Infrastructure
    ├── PermissionManager
    └── Settings
```

要求：

- 单一职责
- 面向接口编程
- 翻译引擎可替换
- Mail 数据来源可替换
- UI 不直接依赖具体 Translation Engine
- Parser 不依赖 UI
- Cache 不依赖具体模型

---

## 14. MVP

第一版只实现：

```text
✓ macOS 原生 App
✓ Apple Mail
✓ Translate 触发入口
✓ 获取当前邮件
✓ HTML / MIME 解析
✓ Apple Translation
✓ 外语 → 简体中文
✓ 保留 HTML 排版
✓ 原图片保留
✓ WKWebView 展示
✓ 右侧吸附 Sidebar
✓ 翻译缓存
```

暂时不做：

```text
× 图片翻译
× DeepSeek / OpenAI
× 自动翻译所有邮件
× Outlook / Spark
× AI 摘要
× AI 回复
× 云端账号
```

---

## 15. 最终体验

用户日常只需要：

```text
打开邮件
   ↓
点击 Translate
   ↓
右侧出现中文版邮件
```

产品应尽量做到：

> 用户感觉这不是一个独立工具，而像是 Apple 原本就给 Mail 加了一个翻译侧栏。