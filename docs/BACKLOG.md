# 待办 / 已知技术债

按"先做哪个"排序，每条都写清**代价是什么**，而不只是"缺个文件"。

状态：⬜ 未开始 · 🟨 进行中 · 🟩 完成 · ⏸ 暂缓

---

## 1. ⏸ `InspectorModel` 无法单元测试（架构债）

**现象**：`App/InspectorModel.swift`（548 行，全 App 最大的逻辑文件）是全项目
**唯一一个没有任何测试的逻辑文件**。其他模块都有：`Cache` 17 个、`MIMEHeaders`、
`HTMLPipeline`、`MIMEDecoder`、`MailIntegration`……

**根因**：它在内部直接构造 / 抓取具体依赖，没有注入口。

```swift
AppleTranslationEngine()            // 第 30、348 行，直接 new
TranslationCache.shared             // 第 157、421、451、452 行，单例
MailSelectionMonitor.shared         // 第 250 行，单例
MessageStore.all() / .rawMessage()  // 7 处，静态调用
EmailInspector.analyze() / .apply() // 4 处，静态调用
UserDefaults.standard               // 3 处
```

于是想测「缓存命中时走哪条分支」，缓存却是写死的 `TranslationCache.shared`
（会读写真实的 `~/Library/Caches`）；想测「跟随 Mail 时该不该切换」，
`MailSelectionMonitor` 是 `private init()` 的单例，会真的去跑 AppleScript。
**没有替换点，就写不了测试。**

**实际已经咬到我们**：一轮会话里改了 `InspectorModel` 三次行为
（M7 加缓存命中、加"绕过缓存重翻"、改成"重翻你看的那封"），三次都只能靠
真机手测，没有测试兜底。

**为什么值得修**：接下来三件事都会继续改这个类 —— M8 的首次引导与错误提示、
接 LLM 引擎（第 348 行那个硬编码的 `AppleTranslationEngine()` 会再多一个分支）、
以及真机跑出来的任何 UI 问题。

**最小的可收益版本**（不是抽一个 `AppDependencies` 做大重构）：
只给挡路的四个东西加注入口 —— 缓存、邮件仓库、选择监听、引擎。
模块本身其实**已经留好了口子**（`TranslationCache(directory:)`、
`TranslationEngine` 是 protocol），只是 App 层没用；真正要动的是
`MailSelectionMonitor` 那个 `private init()`。预计 1–2 小时。

**计划里的原始描述**见 `IMPLEMENTATION_PLAN.md` §3.1 与 M1 行
（"组合根 `AppDependencies`：唯一知道所有具体类型的地方"）。
注意那句"缺组合根"有点误导：听起来像少交了个文件，价值其实在"能不能测"上。

---

## 2. ⏸ M6 吸附侧栏

窗口能手动并排，但**不自动跟随 Mail**。源码里没有任何窗口跟随逻辑
（无 `CGWindowList`）。用户当前工作流是手动并排，体验已等同侧栏。
见 `IMPLEMENTATION_PLAN.md` §9.1 ② 与 D8。

---

## 3. ⏸ M5 移出的「渐进更新」

长邮件现在是"先占位、翻完一次性替换"，不是边翻边显示。
当初明确移出（§9.1 ③），等有需要再说。

---

## 4. ⏸ LLM 引擎

`PRODUCT.md` 列在"暂时不做"，但它是解决"孤立片段保留原文"（见下）的正路，
也是翻译质量的天花板所在。

设计已定：**把整封邮件正文作为上下文送进去，但只让它返回译文数组，
绝不返回 HTML**（§9.2 / 用户确认）。输入 token 不值钱，输出 token 才值钱。

---

## 5. ⬜ 首次使用与错误提示（M8 的前两件）

- **首次引导**：装完打开只有一段文字说"去 Mail 里点横幅"，用户得自己摸到
  「Mail → 设置 → 扩展 → 勾选」。应检测扩展是否启用并给出可直接照做的下一步。
- **错误提示不可行动**：现在界面给的是「翻译失败：\<detail\>」
  「翻译会话不可用：\<detail\>」，准确但没说该怎么办。
  最典型的是**语言包没装** —— 应明确提示并提供一键触发下载。
- **启动自检结果只落盘**：写在 `~/Library/Logs/Mailingo/translation-selftest.log`，
  用户看不到；出问题时应浮到界面上。

---

## 6. ⬜ 中英文界面 / 正式签名与公证

前者只给中文用户用可以不做；后者要给别人用才需要。

---

## 待观察：切邮件时上一封"闪一下"

**状态**：⏳ 已做两轮修复，等真机确认。

用户在 Mail 里快速切邮件（尤其是从一封很大的、带很多图的邮件切走）时，
会看到上一封**一闪而过**，然后才跳到正确的那封。

已定位到的是**发现延迟**，不是状态写回：

- `state == .loading` 时 WebView 会被销毁，不存在"旧 WebView 晚到"的渲染竞态。
- 所有 `inspection` 写入都在 `translate` 里、都有 `runToken` 守卫；
  `state` / `analysis` 的写入有 `loadToken` 守卫。
- 所以剩下的只有一件事：用户点了之后，App 要过一会儿才知道。
  而这段窗口里上一封刚好解析完并画了出来。

已做的两轮：
1. 载入路径加取消 + 代次（`2decdc5`）。
2. 监听邮件目录，一有动静就立刻去问 Mail，不再干等定时器
   （`startWatchingMessagesDirectory`）。定时器同时减到 0.5s 作兜底。

**注意第 2 条依赖一个未在本机验证的假设**：Mail 在用户点开一封**已经解码过**的
邮件时，会不会再次调用 `decodedMessage`。如果不调用，目录监听就不会触发，
只能退回定时器的 0.5s。已加 os_log 追踪（`make stream`），一次复现即可确认。

**如果还是闪**，下一步按这个顺序试：
1. 看追踪确认目录监听到底有没有在点击时触发。
2. 没有 → 降定时器间隔（0.25s），或改成"检测到活跃时临时高频"。
3. 有但仍然闪 → 说明瓶颈在 AppleScript 往返本身，需要考虑别的方式拿到选中项。

---

## 已知的产品局限（不是 bug，是设计取舍）

- **被行内标签切开的孤立虚词保留原文**：Apple 翻译看不到上下文，
  翻了还不如不翻（`isContextlessOrphan`）。LLM 引擎能解决（见第 4 条）。
- **外部图片默认阻断**：远程追踪像素与 emoji 图片都不加载，由用户手动放行。
- **不能翻 Mail 之外的客户端**：架构 C 绑定 Mail 扩展点。
