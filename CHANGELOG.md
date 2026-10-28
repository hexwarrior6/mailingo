# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed / 修复
- Preserve newsletter image-column proportions across separate event tables instead of sizing each row from its text content.
- Retain authored container widths, paired floating tables and responsive media queries, including registration tickets with QR codes and wallet buttons.
- Allow long text to wrap in narrow windows and let multi-column footers accommodate fixed-size social icons.

## [0.1.1] - 2026-10-23

### Fixed / 修复
- **响应式排版防截断 (Responsive Layout)**: 修复营销邮件（如 Figma、WellFest 等）在分栏窄屏下正文长段落被硬截断的问题。将 `nowrap` 限制在叶子节点，防止外层大容器被撑破。
- **页脚小图标居中与间距 (Social Media Icons)**: 修复多图标栏（如 5 个社媒图标）被强制拉大或推向屏幕两端的问题，保留小图标自身尺寸，自适应居中排布。
- **多列落款签名保护 (Signature Layout)**:
  - 保护落款 Logo 列最小宽度（140px），防止 WebKit 算法将其压缩变形；
  - 保障社媒小图标具备充足排布空间（90px），彻底消除图标与相邻文本（如 `@caontusg`）的重叠。
- **清除表格浮动影响 (Float Reset)**: 清除 Outlook 签名表格自带的 `align="left"`（对应 `float: left`）属性影响，并为水平分割线 `<hr>` 强制增加 `clear: both`，彻底解决“保密声明 / 法律声明”在签名收缩后爬升至右侧窄缝折行的排版异常。
- **图片翻译角标靶向过滤 (Overlay Filtering)**: 优化图片翻译判定规则，自动识别并排除落款签名 Logo 与长条装饰图，不再给校徽徽标误加遮挡性的「文A」按钮。

### Added / 新增
- **附件图片末尾渲染 (Attachment Images)**: 支持解析纯附件形态的图片，并按 Apple Mail 习惯自动在邮件正文末尾呈现。

---

## [0.1.0] - 2026-10-22

### Added / 初始发布
- 首个正式版本发布。
- 基于 MailKit 的原生 Apple Mail 邮件翻译扩展。
- 左右分栏双语对照视图，支持拖拽调节宽度。
- 保留原始排版的高保真 HTML 翻译与拼接管线。
- 内联 CID 图片改写与隐私保护（远程图片按需加载）。
- 图片翻译角标与 OCR 翻译集成。
- 历史引用折叠与本地高性能缓存。
