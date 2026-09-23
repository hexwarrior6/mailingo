# Mailingo

为 Apple Mail 提供「一键全文翻译」的原生 macOS 应用：打开一封外语邮件，点一下，
右侧立即出现一份**中文版邮件镜像**——保留原有排版、表格、按钮和图片，
而不是把文字丢出来重新排版。

产品定位与完整需求见 **[docs/PRODUCT.md](docs/PRODUCT.md)**。

---

## 当前状态

**S0 探针已通过，架构确定。** 尚未开始产品功能实现。

| 阶段 | 状态 |
|---|---|
| 需求基线（`docs/PRODUCT.md`） | ✅ |
| 技术方案（`docs/IMPLEMENTATION_PLAN.md`） | ✅ 架构 C 已定 |
| S0 探针：Mail 扩展能否作入口 + 数据源 | ✅ **四问全过**，见 [docs/S0-PROBE.md](docs/S0-PROBE.md) |
| M3 EmailCore（MIME 解码 + HTML 字节切片管线） | ⬜ 下一步 |

S0 的关键结论：Mail 扩展（Message Security 扩展点）能在**阅读窗格**挂横幅，
并由 Mail 把**原始 MIME 直接交给扩展**——因此整条链路
**不需要 Automation / Apple Events 权限**。

架构：**扩展做入口与数据源 + 容器 App 做吸附式侧栏**。

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
├── App/                   # 容器 App（探针阶段是看板；将来承载吸附式侧栏）
├── MailExtension/         # Mail 扩展（appex）
├── Shared/                # App 与 appex 共用代码
├── Scripts/               # 校验与判定脚本
└── docs/
    ├── PRODUCT.md              # 产品需求（需求基线）
    ├── IMPLEMENTATION_PLAN.md  # 技术方案、架构取舍、里程碑、风险
    └── S0-PROBE.md             # S0 探针运行手册与实测结论
```

`.xcodeproj`、`Support/`（Info.plist）、`.build/`、`.tools/` 都是生成物或本地工具，
不进版本控制。**克隆后先跑 `make bootstrap`。**

---

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

---

## 权限原则

只申请真正需要的权限：

- ✅ Mail 扩展：**零额外权限**（原始 MIME 由 Mail 主动递给扩展）
- ✅ 跟随 Mail 窗口：**零权限**（`CGWindowListCopyWindowInfo` 读 bounds）
- ⬜ 读取当前邮件（备用路径 ⌥T）：Automation / Apple Events
- ⬜ 让 Mail 让出空间（V1.1 可选）：Accessibility

**不使用 Full Disk Access，不直接读取 `~/Library/Mail/`。**
详见 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) §5。
