# S0 探针 Runbook

> **S0 的唯一问题**：Mail 扩展能否既当「翻译入口」又当「邮件数据源」？
> 这个答案决定走 **架构 C**（扩展 + 容器 App）还是退回 **架构 A**（⌥T + Apple Events）。
> 背景见 `docs/IMPLEMENTATION_PLAN.md` §0① 与 §2.5。

---

## ✅ 结论：S0 通过 —— 采用架构 C

**2026-09-23 实测通过。** 四个问题全部命中：

| # | 问题 | 结果 |
|---|---|---|
| 1 | 普通未加密未签名邮件会不会调用 `decodedMessage(forMessageData:)`？ | ✅ **会**。一封 NTU/Exchange 的普通通知邮件就触发了 |
| 2 | 返回非 nil + banner 后 Mail 会不会渲染横幅？ | ✅ 会。`primaryActionClicked` 被点击并回调 |
| 3 | 点横幅后 Mail 会不会呈现我们的 `MEExtensionViewController`？ | ✅ 会 |
| 4 | `data` 是不是完整原始 MIME？ | ✅ 是。30496 字节，含完整头部与正文 |

实测日志（pid 36730，即 appex 进程）：

```
★ MailingoMailExtension 已实例化（Mail 加载了扩展）
MailingoMailExtension.handlerForMessageSecurity() 被调用
★ decodedMessage(forMessageData:) 被调用
  bytes = 30496
★ primaryActionClicked(forMessageContext:) 被调用 context="mailingo-s0-probe" → 呈现探针 VC
```

**连带的重大收益**：整条链路**零 Automation / Apple Events 权限** ——
原始 MIME 是 Mail 主动递给扩展的。权限面从"能读你所有邮件"缩到"Mail 递给你的那一封"。

### 从真实邮件里学到的（直接影响 EmailCore 设计）

分析 `last-message.eml` 得到的实测事实：

1. **Mail 递给扩展的 MIME 是 LF 行尾**，不是 RFC 5322 的 CRLF（`file` 报 `ASCII text`，CRLF 行数 = 0）。
   说明 Mail 已经做过归一化。但**仍然必须同时支持 LF 和 CRLF** —— 不能假设。
2. **头部区可能很长**：一封 Exchange 通知的头部有 **152 行**，`From` 在第 40 行、`Subject` 在第 44 行，
   单行最长 970 字符。任何"只看前 8KB 头部"的取巧写法都会踩空。
3. **同一封邮件 `decodedMessage` 会被调用多次**（实测一次浏览触发 3 次相同 30496 字节）。
   → 印证了 `IMPLEMENTATION_PLAN.md` §4.8 的缓存设计是刚需，不是优化。
4. 该样例结构是最常见的 `multipart/alternative` = `text/plain`(3747B) + `text/html`(22989B)，
   **无 Content-Transfer-Encoding、charset=us-ascii**。

### 探针自身踩到的两个解析 bug（已修，教训要带走）

都是"拿一封真实 `.eml` 跑一遍就立刻暴露"的类型，正好印证 §6 的 fixture 黄金测试策略：

1. **头部名大小写不敏感**：原码写成 `line.lowercased().hasPrefix(key + ":")` ——
   左边转小写、右边却是 `"Subject:"` 的原始大小写，于是**永远不匹配**。
2. **Swift 里 `"\r\n"` 是单个 Character**：
   - `components(separatedBy: .newlines)` 会给 CRLF 多切出空段，导致循环提前 `break`；
   - `split(separator: "\n")` 更糟，**完全不在 CRLF 处切分**（整封邮件变一行）；
   - 正确写法：`split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)`。

---

## 这个探针在验什么

`MailExtension/TranslationSecurityHandler.swift` 对 **4 个问题** 打日志：

| # | 问题 | 为什么关键 |
|---|---|---|
| 1 | `decodedMessage(forMessageData:)` 对**普通未加密未签名邮件**会不会被调用？ | 这是整条路线的 go/no-go。SDK 文档只暗示"Mail 会询问"，没有明确保证 |
| 2 | 返回非 nil 的 `MEDecodedMessage` + `banner` 后，Mail 会不会真的渲染横幅？ | 决定"Mail 内入口"是否存在 |
| 3 | 点横幅/头部图标后，Mail 会不会呈现我们自己的 `MEExtensionViewController`？ | 决定我们能否在 Mail 里放自己的 UI |
| 4 | `data` 参数是不是**完整原始 MIME**？ | 决定它能否直接喂给 MIME → HTML 管线 |

**已确认的副产品**：如果 1、3、4 成立，那么翻译链路**完全不需要 Automation / Apple Events 权限** —— 数据是 Mail 主动递给扩展的。这比架构 A 的权限模型干净得多。

---

## 运行步骤

### 1. 构建 + 注册

```bash
cd /Users/zhuyuhao/ZYHCodeSpace/mailingo
make build
```

构建产物：`.build/DerivedData/Build/Products/Debug/Mailingo.app`（appex 已嵌入并签名）。
构建过程会自动 `lsregister`，LaunchServices 已能查到
`com.zhuyuhao.Mailingo.MailExtension` → extension point `com.apple.email.extension`。

### 2.（推荐）把 App 放到 /Applications

从构建目录运行时，LaunchServices 记录的 `_LSDirectoryClass = 7`（开发目录）。
Mail 对扩展的发现**可能**只在 /Applications 这类目录下生效 —— 这正是 S0 要顺带确认的事之一。

```bash
make install-app     # 会先跑 make verify-appex，校验不过就拒绝安装
```

若不想动 /Applications，可先跳过；如果第 3 步在 Mail 设置里看不到 Mailingo，再回来执行它。

### 3. 在 Mail 里启用扩展

1. **完全退出 Mail**（⌘Q，不是关窗口）—— Mail 只在启动时扫描扩展。
2. 重新打开 Mail。
3. 打开 **Mail → 设置 → 扩展**，勾选 **Mailingo**。

> 如果列表里没有 Mailingo：先确认 `make install-app` 已执行、Mail 已完全重启；
> 仍没有就检查 系统设置 → 隐私与安全性，是否有被拦截的扩展提示。

### 4. 产生数据

1. 打开**几封普通的外语邮件**（不要用 S/MIME 加密/签名的，那会干扰判定）。
2. 回来看日志：
   ```bash
   make status     # 判定摘要
   make log        # 实时跟随原始日志
   ```

### 5. 点横幅，验证入口

邮件顶部应该出现一条横幅：**「Mailingo 探针：翻译这封邮件」**，右侧有 **「翻译」** 按钮。
点它（或邮件头部的扩展图标），应该弹出我们自己的视图控制器，里面显示原始 MIME 与日志。

然后再跑一次 `make status`。

---

## 两种行为对比（不用重装、不用重启 Mail）

探针支持运行时切换，方便分离"会不会被调用"和"横幅会不会渲染"两个问题：

```bash
CONTAINER=~/Library/Containers/com.zhuyuhao.Mailingo.MailExtension/Data/Library/Logs/Mailingo
touch "$CONTAINER/return-nil"   # 返回 nil：只观察是否被调用（基线）
rm    "$CONTAINER/return-nil"   # 返回非 nil：观察横幅是否渲染（默认）
```

容器 App 看板里也有同样的开关按钮。改完回 Mail 重新点一封邮件即可生效。

---

## 结果怎么读

| 观察 | 含义 | 结论 |
|---|---|---|
| 1 通过、3 不通过 | 扩展被调用、能拿到 MIME，但 UI 出不来 | 架构 C 可做"静默数据源"，入口退回 ⌥T |
| 1 不通过（普通邮件从不调用） | S/MIME 扩展点只处理加密/签名邮件 | **架构 C 不成立 → 退回架构 A** |
| 1、2、3、4 全通过 | 一切成立 | **架构 C**，且无需 Automation 权限 |
| 3 通过但 Mail 显示了错误的安全状态 UI | 借用扩展点的副作用 | 记录观感，评估是否可接受；必要时只做横幅不声明签名信息 |

---

## 落盘位置

**appex 必须沙盒化**（见下方"已知的环境注意点"），所以它的日志写在**自己的沙盒容器**里；
容器 App 是非沙盒的，能直接读这个绝对路径。

| 文件 | 内容 |
|---|---|
| `~/Library/Containers/com.zhuyuhao.Mailingo.MailExtension/Data/Library/Logs/Mailingo/probe.log` | 追加式事件日志（含 pid，可区分 appex 进程与容器 App） |
| `…/Data/Library/Logs/Mailingo/last-message.eml` | 最近一次拿到的原始 MIME，用于验证完整性 |
| `…/Data/Library/Logs/Mailingo/return-nil` | 行为开关 |

> 早先非沙盒版本往 `~/Library/Logs/Mailingo/` 写过；`make status` 会自动兼容那个旧位置。

也可以从 os_log 看：

```bash
make stream
# 等价于：log stream --style compact --predicate 'subsystem == "com.zhuyuhao.Mailingo"'
```

---

## 已知的环境注意点

以下三条都是**踩过的坑**，症状都极具迷惑性，用 `make verify-appex` 一次性兜住。

1. **★ appex 必须沙盒化**（`ENABLE_APP_SANDBOX: YES`，只对 appex target）。
   macOS 要求 app 扩展带 `com.apple.security.app-sandbox`，否则 **pkd 不注册它**：
   - `pluginkit -m -p com.apple.email.extension -v` → `(no matches)`
   - Mail → 设置 → 扩展 → **空列表**
   而与此同时 `codesign --verify` 通过、LaunchServices 里也能查到、App 能正常打开 —— 极具误导性。
   Xcode 的 Mail Extension 模板默认就是 `ENABLE_APP_SANDBOX = YES`，**不要全局关掉它**。
   容器 App 仍然保持非沙盒（它以后要用 Accessibility，见 `IMPLEMENTATION_PLAN.md` §5.2）——
   两者不冲突：沙盒的是 appex，不是 App。

2. **★ 必须关闭 `ENABLE_DEBUG_DYLIB`**（已写在 `project.yml`）。
   Xcode 16+ 在 Debug 下默认把真实代码挪进 `xxx.debug.dylib`，主可执行文件只剩一个 56KB stub。
   而 **App 扩展没有 `main()` 入口** —— 宿主是 dlopen appex 再按 `NSExtensionPrincipalClass`
   查类，stub 的 `main()` 永远不跑，类就没注册。
   症状与上一条几乎一样：注册成功、签名 OK、App 能开，但 Mail 看不到扩展。

   校验方式：
   ```bash
   make verify-appex
   # 检查：debug dylib / MailKit 链接 / app-sandbox / principal class 符号 / extension point
   ```

3. **构建需要 `-disable-sandbox`**（已写在 `project.yml`）。
   Swift 宏（`#Preview`、`@Observable`）会让编译器用 `sandbox-exec` 启动 `swift-plugin-server`；
   在已经是沙盒的构建环境（CI、本仓库的 agent 沙盒）里嵌套会失败：
   `sandbox-exec: sandbox_apply: Operation not permitted`。
   这个 flag 只关掉编译期子进程的沙盒，**不影响产物的沙盒/签名设置**。
4. **签名身份必须保持稳定**。Mail 与 TCC 的授权绑定代码签名；换签名会导致重新授权。
   本仓库固定使用 `Apple Development: … (9D88N9XJZ3)` / team `75Q23985G5`（手动签名，无需 provisioning profile）。
5. **本会话内 `pluginkit` 不可用**（返回 `unauthorized discovery flag (PKDiscoverAll)`），
   `log show` 也会报 `Cannot run while sandboxed`。排查扩展注册情况请在**你自己的终端**里跑：
   ```bash
   pluginkit -m -p com.apple.email.extension -v
   make diagnose    # os_log + 进程是否被拉起 + 注册情况 + 容器内容，一次看全
   ```
6. **探针日志是同步落盘的，别改成异步**。appex 是 Mail 拉起的短生命周期进程，
   早先版本用 `queue.async` 写文件，结果**目录建好了、日志却一行没有** ——
   进程在异步块执行前就退出了。排障场景下"宁可阻塞也要写下去"，
   并且写完要 `FileHandle.synchronize()` 显式 flush。
   appex 写文件也必须用沙盒重定向后的路径（`.libraryDirectory`），而不是硬拼容器绝对路径。
