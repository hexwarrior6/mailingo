<div align="center"><a name="readme-top"></a>

<img height="120" src="./docs/assets/icon.png" alt="Mailingo 图标">

<h1>Mailingo</h1>

为 Apple Mail 提供一键全文翻译的原生 macOS 应用 —— 1:1 像素级排版镜像，开窗即读，关窗即退。

[![Platform](https://img.shields.io/badge/平台-macOS%2015.0%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift)](https://swift.org)
[![MailKit](https://img.shields.io/badge/扩展-MailKit-5856D6)](https://developer.apple.com/documentation/mailkit)
[![WebKit](https://img.shields.io/badge/渲染-WebKit-000000?logo=safari)](https://webkit.org)
[![Website](https://img.shields.io/badge/官网-访问-brightgreen)](https://hexwarrior6.github.io/mailingo/)
[![License](https://img.shields.io/badge/开源协议-MIT-green.svg)](LICENSE)

[官方网站](https://hexwarrior6.github.io/mailingo/) · [English](README.md) · 简体中文

</div>

---

## 💡 项目简介

**Mailingo** 是一款为 Apple Mail 量身打造的原生 macOS 邮件翻译伴侣。

当收到外语邮件时，点击 Apple Mail 阅读窗格顶部的横幅按钮，右侧便会即刻弹出对应的**中文版邮件镜像**。不同于传统翻译工具将文字剥离后的重新排版，Mailingo 采用高保真 HTML 切片替换管线，**完整保留原有排版结构、复杂表格、按钮样式、CSS 样式与内嵌图片**。

<div align="center">
  <img src="./docs/assets/screenshot-main.png" alt="Mailingo 主界面截图" width="100%">
  <p><em>Apple Mail 阅读窗格与顶部翻译横幅（左）及 Mailingo 1:1 镜像译文窗口（右）</em></p>
</div>

---

## ✨ 核心特性

| 功能特性 | 技术实现 | 解决痛点 |
| :--- | :--- | :--- |
| **📑 1:1 版面镜像高保真** | 字节级 HTML 切片替换管线 | 完美保留响应式表格、CSS 样式、按钮与图文混排，彻底告别剥离纯文本导致的排版错乱。 |
| **📬 Mail 原生横幅接入** | macOS 邮件安全扩展点（Message Security） | 在 Mail 阅读窗格顶部直接显示翻译入口；由 Mail 递送原始 MIME，**无需额外自动化（Automation）授权**。 |
| **🖼️ CID 内嵌图解析** | 自定义 WebKit Scheme 处理器 (`mailingo-cid://`) | 正确解析和渲染签名档 Logo、邮件内嵌截图等 `cid:` 资源，解决 WebKit 原生不认该协议导致的空白问题。 |
| **🛡️ 隐私防追踪拦截** | 默认阻断远程外链图片，禁用 JS 脚本执行 | 拦截邮件营销追踪像素（Tracking Pixel），防止发件人探知阅读时间；提供醒目横幅支持一键按需载入。 |
| **💬 智能历史引用折叠** | 自动识别 Apple Mail、Gmail、Outlook 及 `>` 引用标记 | 智能折叠冗长的多轮历史邮件回复，只翻译当前新增正文，避免重复翻译消耗并提升阅读体验。 |
| **⚡ 关窗即退 · 零常驻内存** | 窗口关闭即刻调用进程退出 | 不常驻后台守护进程，不用时不占 1 字节内存；支持跟随 Apple Mail 阅读窗口关闭自动联动退出。 |
| **💾 智能本地翻译缓存** | 基于 LRU 淘汰的本地磁盘缓存（可设时间与上限） | 同一封邮件只需翻译一次，二次打开秒级呈现，同时提供强制刷新旁路便于纠错重翻。 |

---

## 📥 安装与使用

### 下载安装包

从以下渠道直接下载最新版本 `Mailingo.dmg`：
- **[官方网站](https://hexwarrior6.github.io/mailingo/)**
- **[GitHub Releases 发行版](https://github.com/hexwarrior6/mailingo/releases)**

1. 双击打开 `Mailingo.dmg`，将 **Mailingo.app** 拖入「应用程序（Applications）」文件夹。
2. 在「应用程序」中启动一次 Mailingo，以向系统注册 MailKit 邮件扩展。

> [!TIP]
> **初次打开提示未签名 / 损坏？**  
> Mailingo 为个人开源项目，未购买苹果年费开发者证书。若初次打开时 macOS 弹出安全拦截提示，只需打开终端（Terminal）执行以下命令移除隔离属性即可正常运行：
> ```bash
> xattr -cr /Applications/Mailingo.app
> ```

---

## ⚙️ 在 Apple Mail 中启用

1. **完全退出 Apple Mail**（按 `⌘Q`，非单纯关闭窗口；Mail 仅在冷启动时扫描并加载新扩展）。
2. 重新打开 Apple Mail → **设置** (`⌘,`) → **扩展** 页签。
3. 勾选 **Mailingo** 扩展。
4. 打开任意邮件，阅读窗格上方即会出现 Mailingo 翻译横幅。

---

## 🛠️ 从源码编译（开发者）

如需二次开发或自行本地编译：

### 环境要求

- macOS 15.0+ (Sequoia)
- Xcode 16+ (Swift 6.0+)
- 本地 Apple Development 签名证书（系统加载 Mail 扩展时必需）

### 编译步骤

```bash
# 1. 下载工程管理工具 XcodeGen
make bootstrap

# 2. 编译、签名并安装至 /Applications 目录
make install-app
```

---

### 发布新版本

`CHANGELOG.md` 和 GitHub Release 说明统一使用英文；生成器沿用既有的发布小节和安装说明格式。

1. 开发期间，将面向用户的变更写入 `CHANGELOG.md` 的 `Unreleased` 部分。
2. 发布前，将这些变更移到带日期的版本小节（如 `## [0.1.2] - 2026-10-28`），更新 `project.yml` 中的 `MARKETING_VERSION`，并递增 `CURRENT_PROJECT_VERSION`。
3. 提交并推送代码，然后创建和推送对应标签（如 `v0.1.2`）。

Release Build 工作流会校验版本与 changelog、执行测试、构建应用，并发布 DMG、ZIP 和 SHA-256 校验和。GitHub Release 的变更说明自动读取该版本的 changelog。手动重跑时，在工作流输入中填写已存在的版本标签。

本地预览发布说明：

```bash
python3 Scripts/release-notes.py v0.1.2 .build/release-notes.md
```

## 🛠️ 项目结构

```text
mailingo/
├── App/                   # 容器 App（SwiftUI 界面与 WebKit 渲染器）
├── MailExtension/         # Apple Mail 原生扩展（MailKit 安全扩展点）
├── Shared/                # App 与扩展共享代码及 App Group 容器存储
├── Packages/
│   └── MailingoKit/       # 核心模块（EmailCore MIME与HTML解析、TranslationCore、缓存）
├── Design/                # 图标与界面源文件（原始画稿）
├── Scripts/               # 自动化构建、图标生成、检验与诊断脚本
└── docs/                  # 详细产品与技术设计方案文档
    ├── PRODUCT.md         # 产品需求基线
    ├── IMPLEMENTATION_PLAN.md # 核心技术架构、方案取舍与技术风险
    └── S0-PROBE.md        # MailKit 扩展可行性实测结论报告
```

---

## 📖 深入文档

如需了解底层技术实现细节、架构取舍与踩坑排错经验：
- **[产品需求基线 (PRODUCT.md)](docs/PRODUCT.md)** — 核心业务场景、Sidebar 交互规格与设计要求。
- **[技术实现方案 (IMPLEMENTATION_PLAN.md)](docs/IMPLEMENTATION_PLAN.md)** — HTML 字节切片替换管线、WebKit 自定义 Scheme 处理与缓存机制。
- **[S0 探针实测报告 (S0-PROBE.md)](docs/S0-PROBE.md)** — MailKit 扩展点可行性验证与 macOS 沙盒注意事项。

---

## 📄 开源协议

本项目采用 MIT 许可证开源 - 详见 [LICENSE](LICENSE) 文件。
