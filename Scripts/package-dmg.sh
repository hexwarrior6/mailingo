#!/usr/bin/env bash
# 制作 Mailingo 预编译分发产物（DMG 镜像与 ZIP 包）
#
# 用法：
#   Scripts/package-dmg.sh [APP_PATH] [OUTPUT_DIR]
# 默认：
#   APP_PATH:   .build/DerivedData/Build/Products/Release/Mailingo.app
#   OUTPUT_DIR: .build/dist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="${1:-$ROOT_DIR/.build/DerivedData/Build/Products/Release/Mailingo.app}"
OUTPUT_DIR="${2:-$ROOT_DIR/.build/dist}"

if [ ! -d "$APP_PATH" ]; then
  # 降级尝试 Debug 目录
  DEBUG_APP="$ROOT_DIR/.build/DerivedData/Build/Products/Debug/Mailingo.app"
  if [ -d "$DEBUG_APP" ]; then
    echo "⚠️ 未找到 Release 产物，使用 Debug 产物：$DEBUG_APP"
    APP_PATH="$DEBUG_APP"
  else
    echo "❌ 找不到 Mailingo.app：$APP_PATH"
    echo "   请先编译：make build CONFIG=Release"
    exit 1
  fi
fi

echo "📦 正在准备打包分发产物..."
echo "  源应用: $APP_PATH"
echo "  输出目录: $OUTPUT_DIR"

# 1. 验证并保留 entitlements 进行签名补全
APPEX_PATH="$APP_PATH/Contents/PlugIns/MailingoMailExtension.appex"
echo "🔏 检查代码签名（保留 entitlements）..."
if [ -d "$APPEX_PATH" ]; then
  codesign --force --preserve-metadata=entitlements,requirements,flags --sign - "$APPEX_PATH" 2>/dev/null || true
fi
codesign --force --preserve-metadata=entitlements,requirements,flags --sign - "$APP_PATH" 2>/dev/null || true

# 2. 验证 appex 完整性
if [ -x "$SCRIPT_DIR/verify-appex.sh" ]; then
  echo "🔍 校验 appex 结构..."
  bash "$SCRIPT_DIR/verify-appex.sh" "$APP_PATH"
fi

# 3. 准备输出目录与暂存区
mkdir -p "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d -t mailingo-dmg-XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "📁 复制 App 到临时镜像区..."
ditto "$APP_PATH" "$STAGING_DIR/Mailingo.app"

# 创建指向 /Applications 的快捷方式软链接
ln -s /Applications "$STAGING_DIR/Applications"

# 4. 生成 DMG
DMG_PATH="$OUTPUT_DIR/Mailingo.dmg"
TEMP_DMG="$(mktemp -t mailingo-out-XXXXXX).dmg"
echo "💿 制作 DMG 镜像 ($DMG_PATH)..."
rm -f "$DMG_PATH" "$TEMP_DMG"
hdiutil create \
  -volname "Mailingo" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$TEMP_DMG"

mv -f "$TEMP_DMG" "$DMG_PATH"

# 5. 生成 ZIP（作为备选下载）
ZIP_PATH="$OUTPUT_DIR/Mailingo.zip"
echo "🗜️ 制作 ZIP 压缩包 ($ZIP_PATH)..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# 6. 输出结果与 SHA256 校验和
echo ""
echo "✅ 打包完成！生成分发文件："
ls -lh "$DMG_PATH" "$ZIP_PATH"
echo ""
echo "🔐 SHA-256 校验和："
shasum -a 256 "$DMG_PATH" "$ZIP_PATH"
