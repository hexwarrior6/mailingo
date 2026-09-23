# Mailingo

为 Apple Mail 提供「一键全文翻译」的原生 macOS 应用：打开一封外语邮件，点一下，
右侧立即出现一份**中文版邮件镜像**——保留原有排版、表格、按钮和图片，
而不是把文字丢出来重新排版。

产品定位与完整需求见 **[docs/PRODUCT.md](docs/PRODUCT.md)**。

---

## 当前状态

**M4（翻译引擎）已完成，端到端能出中文。** 下一步是 M5 正式渲染。

| 阶段 | 状态 |
|---|---|
| 需求基线（`docs/PRODUCT.md`） | ✅ |
| 技术方案（`docs/IMPLEMENTATION_PLAN.md`） | ✅ 架构 C 已定 |
| S0 探针：Mail 扩展能否作入口 + 数据源 | ✅ **四问全过**，见 [docs/S0-PROBE.md](docs/S0-PROBE.md) |
| M3 EmailCore：MIME 解码 + HTML 字节切片管线 | ✅ 23 个单元测试 |
| **M4 TranslationCore：Apple 翻译引擎** | ✅ **端到端跑通**（连续取 session 3/3、实际译文见自检日志） |
| 会话（来回多封）的精确定位 | ✅ 每封按内容 ID 分开存；点横幅翻译的就是**你看的那一封** |
| **M5 Renderer（内嵌图片 + 远程图阻断）** | ✅ 已完成 |
| **跟随 Mail 自动切换（M2 复活）** | ✅ 已完成 |
| M7 翻译缓存 | ⬜ 下一个 |
| M6 吸附侧栏 | ⏸ 缓做（手动把两窗口并排已达到同等效果） |
| M8 打磨（引导页/本地化/公证） | ⏸ 最后再说 |

S0 的关键结论：Mail 扩展（Message Security 扩展点）能在**阅读窗格**挂横幅，
并由 Mail 把**原始 MIME 直接交给扩展**——因此整条链路
**不需要 Automation / Apple Events 权限**。

架构：**扩展做入口与数据源 + 容器 App 做吸附式侧栏**。

### 开发者模式

菜单栏 **「显示 → 开发者模式」**（⌘⇧D）勾选切换，默认**关闭**。

**不是两套界面** —— 只有一处布局代码，用条件分支决定多显示哪些面板：

| | 正常使用（默认） | 开发者模式 |
|---|---|---|
| 选择邮件 / 重新翻译 | ✅ | ✅ |
| 显示模式（原文/译文/双语） | ✅ | ✅ |
| 翻译进度、错误提示 | ✅ | ✅ |
| 切换翻译引擎（标记替换/原样返回） | — | ✅ |
| 「翻译自检」按钮 | — | ✅ |
| 「打开 .eml…」 | — | ✅ |
| 保真指标 chip、MIME 结构、内容 ID | — | ✅ |
| 「提取出的片段」表格 | — | ✅ |
| 「S0 探针」页签 | — | ✅ |

正常模式下引擎被强制为 Apple 翻译，不会翻出一堆 `〖0〗`。

### App 现在能看到什么

打开 Mailingo，**「邮件解析」页签**：

- **内嵌图片（`cid:`）能正常显示**：邮件里的签名 logo、商品图在 HTML 里写的是
  `src="cid:xxx"`，WebKit 不认这个协议、原样渲染会**完全看不见**。
  渲染前会把它改写成自定义 scheme，由 `WKURLSchemeHandler` 从 MIME 里取字节喂回去。
- **外部图片默认不加载**（和 Mail 一致）：远程图片是最常见的追踪手段，
  发件人靠它知道你何时、看了几次。被拦截时预览区上方会明说
  「这封邮件包含 N 张外部图片，已拦截」并给出一键载入 ——
  **没有这句提示的话，用户只会以为图片坏了或 emoji 丢了**
  （真实案例：有营销邮件把 emoji 做成远程图片，拦截后那几个 emoji 凭空消失，
  而同封邮件里的文字 emoji 还在，看起来就是"有些 emoji 显示不出来"）。
- **链接一律跳默认浏览器**，不会在这个小窗格里导航走。
- 邮件里的脚本一律不执行（`allowsContentJavaScript = false`）——
  有这一条就不需要再去 HTML 里剥 `<script>`，那是重复防线。
- **跟随 Mail 自动切换**（可选，默认关）：打开后你在 Mail 里点开哪一封，
  这里就自动切到那一封并翻译。需要「自动化」权限（首次打开会弹系统授权框）。
- **显示模式**：`原文` / `译文` / `双语`（并排对照）三种，选择会记住。
  只看译文在窄窗口（并排放在半屏时）里读数舒服得多。引擎可在三者间切换：
  - **Apple 翻译** —— 系统内置，真译文
  - **标记替换** —— 每个文本节点变成 `〖N〗`，用来看清哪些节点被碰过
  - **原样返回** —— 右侧应与左侧**逐字节相同**，用于验证切片没有副作用
- 顶部指标：`非文本字节一致` / `标签序列一致` / `改动 N 段` / `提取 N 段`
- 翻译进行中显示 `翻译中 40/282` 这样的进度
- **布局可调**：原文/译文之间的分隔线左右拖拽调宽度，预览区与片段列表之间的
  分隔线上下拖拽调高度；底部折叠条点击即可隐藏片段列表，把空间让给预览
  （折叠状态会记住）
- **右上角可以选择邮件**：会话里来回好几封都会列在下拉里，
  点 Mail 里某一封的「翻译」横幅时，这里会自动切到那一封

左右一对比就能确认方案 §6 的核心要求：**表格、图片、颜色、条件注释原样都在，
只有文字被换掉了。** 数据来自 Mail 真实收到的那封邮件（appex 写在沙盒容器里），
也可以用「打开 .eml…」喂样本。

**首次出中文需要下载语言包**：点工具栏的「**翻译自检**」，系统会弹下载确认。
启动时的自动自检**故意不触发下载**，避免没经你同意就弹窗。
自检报告写在 `~/Library/Logs/Mailingo/translation-selftest.log`，含语言对可用性、
语言检测结果、连续取 session 的成功率、以及实际译文抽样。

---

## 环境要求

- macOS 15.0+（开发机实测 15.7）
- Xcode 26（Swift 6.2）
- 一个可用于本地签名的 **Apple Development** 证书
  （Mail 扩展必须由有效签名加载；且签名身份要保持稳定，否则系统会反复重新授权）

## 快速开始

```bash
make bootstrap     # 下载 XcodeGen 到 .tools/（无需 sudo，固定版本）
make install-app   # 构建 + 校验 + 安装到 /Applications + 重新注册
```

然后：

1. **完全退出 Mail**（⌘Q，不是关窗口 —— Mail 只在启动时扫描扩展）
2. 重新打开 Mail → **设置 → 扩展** → 勾选 **Mailingo**
3. 打开几封普通的外语邮件，邮件顶部会出现探针横幅

验证：

```bash
make status        # S0 四问判定摘要
make diagnose      # 地面真相：os_log + appex 是否被拉起 + 注册情况
```

> `make diagnose` 和 `pluginkit` 需要在你自己的终端里跑。
> 某些受限环境（CI、agent 沙盒）里 `log show` 会报 `Cannot run while sandboxed`。

---

## 常用命令

| 命令 | 作用 |
|---|---|
| `make bootstrap` | 下载 XcodeGen 到 `.tools/`（幂等） |
| `make gen` | 由 `project.yml` 生成 `Mailingo.xcodeproj` |
| `make build` | 编译（含 appex 嵌入与签名） |
| `make test` | 跑单元测试（71 个，不需要证书、不到一秒） |
| `make check-render` | 渲染冒烟检查：真的跑一遍 WKWebView，确认 `cid:` 内嵌图能显示 |
| `make verify-appex` | 校验 appex 是可加载的真扩展，而不是空壳 |
| `make install-app` | 构建 + 校验 + 装到 `/Applications` + 重新注册 |
| `make status` | S0 探针四问判定摘要 |
| `make diagnose` | os_log / appex 是否被拉起 / 注册情况 / 容器内容 |
| `make log` / `make stream` | 跟随落盘日志 / 跟随 os_log |
| `make refresh-plugins` | 重新注册扩展并列出 Mail 扩展 |
| `make reset-log` | 清空探针日志与落盘的 MIME |
| `make clean` | 清掉所有生成物 |

---

## 仓库结构

```
.
├── project.yml            # XcodeGen 工程定义（唯一事实来源，.xcodeproj 不入库）
├── Makefile               # 构建 / 安装 / 排查入口
├── App/                   # 容器 App（现在是看板；将来承载吸附式侧栏）
├── MailExtension/         # Mail 扩展（appex）
├── Shared/                # App 与 appex 共用代码
├── Packages/MailingoKit/  # 核心逻辑：EmailCore（只依赖 Foundation）+ TranslationCore
├── Scripts/               # 校验与判定脚本
└── docs/
    ├── PRODUCT.md              # 产品需求（需求基线）
    ├── IMPLEMENTATION_PLAN.md  # 技术方案、架构取舍、里程碑、风险
    └── S0-PROBE.md             # S0 探针运行手册与实测结论
```

`.xcodeproj`、`Support/`（Info.plist）、`.build/`、`.tools/` 都是生成物或本地工具，
不进版本控制。**克隆后先跑 `make bootstrap`。**

---

## 已知的翻译局限（V1）

**被行内标签切开的孤立虚词翻不准**，例如：

```html
<p>Meeting from <b>9:00</b> to <b>11:00</b></p>   <!-- 中间的 to 没有语境 -->
<p>Due on 14<sup>th</sup> March</p>                 <!-- th 只是序数后缀 -->
```

Apple 翻译的接口**只接受"要翻的这段文本"**，看不到上下文，这类片段翻出来往往是错的。

**当前策略**：这类片段**整段保留原文**，不翻 —— 翻错比不翻更糟。
判据是「虚词清单 + 该文本节点与同块级容器内的相邻节点并存」；
独占一个块的短词（如 `<button>No</button>`）有完整语境，照常翻译。

**根治办法是 LLM 引擎**：把整封邮件的文本作为**输入上下文**一起给它，
但只要求它返回译文数组（**不要让模型重写 HTML** —— 那会毁掉排版，
而且输出 token 贵得多）。代码里已经预留好位置：
`TranslationEngine.hasFullContext` 为 `true` 的引擎会收到全部片段，包括孤立虚词。

## 开发时容易踩的坑

这些都在 `docs/S0-PROBE.md` 的「已知的环境注意点」里详述，`make verify-appex`
会一次性兜住前两条：

1. **appex 必须沙盒化**（`ENABLE_APP_SANDBOX: YES`）——macOS 硬性要求，
   否则 `pkd` 不注册它：`pluginkit` 查不到、Mail 扩展面板为空。
   但**容器 App 必须非沙盒**（它以后要用 Accessibility）。沙盒按 target 分开决定。
2. **必须关闭 `ENABLE_DEBUG_DYLIB`**——开启时 appex 主可执行文件只剩 stub，
   而 App 扩展没有 `main()` 入口，宿主按 `NSExtensionPrincipalClass` 查类时
   类根本没注册。症状与第 1 条几乎一样：注册成功、签名 OK、App 能开，但 Mail 看不到。
3. **构建需要 `-disable-sandbox`**——Swift 宏会让编译器用 `sandbox-exec` 启动
   plugin-server，在已是沙盒的构建环境里嵌套会失败。

这三条的症状都是「扩展明明装上了，Mail 里就是没有」，排查时先看第 1、2 条。

**第 4 条（翻译相关，症状最误导）**：`TranslationSession.Configuration` 必须
**复用同一个实例反复 `invalidate()`**，不能每次新建。它的相等性包含 `version`，
而 `invalidate()` 只在当前值上加一 —— 每次新建再 invalidate，每个配置的 version
都是 1、彼此相等，SwiftUI 就认为"配置没变"，**不再触发 `.translationTask`**。

表现是：**第一次翻译完全正常，之后每次都卡在「翻译中 0/N」，直到 30 秒超时报
「等待翻译会话超时」**。看起来像翻译服务变慢，其实是根本没去要 session。
`make test` 里有两条测试把这件事钉住了。

**第 6 条（开发期特有）**：**同时存在两份 App 时，`mailingo://` 会路由到不确定的那一份。**
构建目录和 `/Applications` 各有一份、两份都声明了同一个 URL scheme 时，
`open mailingo://…` 可能拉起"另一份"，看起来像"每点一次就多开一个实例"。
开发时要么只留一份（`make install-app` 之后把构建目录那份从 LaunchServices 注销），
要么用 `open -a <具体路径>` 明确指定。

**第 8 条（被动信号的噪声）**：**Mail 会推送邮件内容，但不推送"用户在看哪一封"。**
`decodedMessage` 回调里有大量批量解码 —— 实测 59 个相邻间隔有 38 个小于 1.5 秒
（滚动列表、预取、打开会话时的批量解码）。所以"切到最新解码的那封"会乱跳。
要知道"当前选中项"只能主动查询（`MailSelectionMonitor` 用 AppleScript 查
`selected messages`），代价是一次「自动化」授权。

**第 7 条（Mail 的交付方式，影响很大）**：**同一封邮件 Mail 会回调两次。**
先给"信封到了、附件还没下载"的版本（内嵌图片部分是**空的**），稍后再给完整版。
实测同一封 Message-ID 两次的字节数能差 **725 倍**（24KB vs 18MB）。
不去重的话：下拉列表里同一封会出现两次；更糟的是可能挑中空壳那份，
于是**内嵌图片全是空白**。`MessageStore.all()` 现在按 `Message-ID` 归组、
保留字节数最多的那份，App 也会在完整版到达时自动换上。

**第 5 条（会话相关）**：**不要把每封邮件写进同一个文件。**
Mail 会把会话里每一封都解码一遍（实测 200 次调用出现十几个不同大小），
谁最后被解码谁覆盖前面 —— 容器 App 拿到的就跟你正在看的那封毫无关系，
表现为「只能识别到第一封」「双击单独打开那封才识别得到」。
现在每封按内容 ID 存 `messages/<id>.eml`，并靠 banner 的 `context`
把「用户点的是哪一封」精确传出来。

---

## 权限原则

只申请真正需要的权限：

- ✅ Mail 扩展：**零额外权限**（原始 MIME 由 Mail 主动递给扩展）
- ✅ 跟随 Mail 窗口：**零权限**（`CGWindowListCopyWindowInfo` 读 bounds）
- ⬜ 读取当前邮件（备用路径 ⌥T）：Automation / Apple Events
- ⬜ 让 Mail 让出空间（V1.1 可选）：Accessibility

**不使用 Full Disk Access，不直接读取 `~/Library/Mail/`。**
详见 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) §5。
