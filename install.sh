#!/usr/bin/env bash
# Mailingo 一键快速安装脚本
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/hexwarrior6/mailingo/main/install.sh | bash

set -euo pipefail

REPO="hexwarrior6/mailingo"
APP_NAME="Mailingo.app"
INSTALL_DIR="/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME"
LATEST_URL="https://github.com/$REPO/releases/latest/download/Mailingo.zip"

echo "=========================================="
echo "  🚀 Mailingo 原生邮件翻译伴侣安装器"
echo "=========================================="

# 1. 检查系统要求
OS_NAME=$(uname -s)
if [ "$OS_NAME" != "Darwin" ]; then
  echo "❌ 错误：Mailingo 仅支持 macOS 系统。"
  exit 1
fi

MACOS_VER=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_VER" -lt 15 ]; then
  echo "⚠️ 警告：Mailingo 基于 macOS 15.0+ (Sequoia) 构建，您的系统版本为 $(sw_vers -productVersion)，可能无法正常运行。"
fi

# 2. 创建临时目录
TMP_DIR=$(mktemp -d -t mailingo-install-XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "⬇️  正在下载最新版 Mailingo..."
if ! curl -fSL --progress-bar "$LATEST_URL" -o "$TMP_DIR/Mailingo.zip"; then
  echo "❌ 下载失败。请检查网络或访问 https://github.com/$REPO/releases 手动下载。"
  exit 1
fi

echo "📦 正在解压并安装到 $INSTALL_DIR..."
unzip -qo "$TMP_DIR/Mailingo.zip" -d "$TMP_DIR"

if [ ! -d "$TMP_DIR/$APP_NAME" ]; then
  echo "❌ 解压异常：未在压缩包中找到 $APP_NAME"
  exit 1
fi

# 3. 替换旧版本
if [ -d "$TARGET_APP" ]; then
  echo "🔄 发现旧版本，正在替换..."
  rm -rf "$TARGET_APP"
fi
cp -R "$TMP_DIR/$APP_NAME" "$TARGET_APP"

# 4. 自动解除 macOS Gatekeeper 隔离（防止未签名拦截）
echo "🛡️  配置本地信任与权限（移除隔离属性）..."
xattr -cr "$TARGET_APP" 2>/dev/null || true

# 5. 注册 MailKit 扩展
APPEX="$TARGET_APP/Contents/PlugIns/MailingoMailExtension.appex"
if [ -d "$APPEX" ]; then
  echo "🔌 正在向系统注册 Apple Mail 扩展..."
  /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$TARGET_APP" 2>/dev/null || true
  pluginkit -a "$APPEX" 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo "  🎉 安装成功！"
echo "=========================================="
echo "接下来仅需两步启用："
echo "  1. 完全退出 Apple Mail（按 ⌘Q，非仅关闭窗口）"
echo "  2. 重新打开 Apple Mail → 设置 (⌘,) →「扩展」页签 → 勾选 Mailingo"
echo ""
echo "享受 1:1 高保真邮件翻译！"
