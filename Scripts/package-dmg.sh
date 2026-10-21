#!/usr/bin/env bash
# 制作 Mailingo 预编译分发产物（DMG 镜像与 ZIP 包）
#
# 采用 Sindre Sorhus 官方现代方案（Lungo / create-dmg 架构）
# 特性：纯净粗线条「>」指示，自动规避 Finder 滚动条，160px 大图标对称居中
#
# 用法：
#   Scripts/package-dmg.sh [APP_PATH] [OUTPUT_DIR]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="${1:-$ROOT_DIR/.build/DerivedData/Build/Products/Release/Mailingo.app}"
OUTPUT_DIR="${2:-$ROOT_DIR/.build/dist}"

if [ ! -d "$APP_PATH" ]; then
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

# 1. 代码签名验证与补全（保留 entitlements 权限元数据）
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

mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/Mailingo.dmg"
ZIP_PATH="$OUTPUT_DIR/Mailingo.zip"

# 3. 采用 Sindre Sorhus 原生方案（零滚动条，纯净粗箭头，居中 160px 图标）
echo "💿 制作极简标准 DMG 镜像..."
rm -f "$DMG_PATH"

if command -v npx >/dev/null 2>&1; then
  echo "🚀 使用 Sindre 官方 create-dmg 构建 (Lungo 架构)..."
  npx --yes create-dmg "$APP_PATH" "$OUTPUT_DIR" \
    --overwrite \
    --no-version-in-filename \
    --no-code-sign \
    --dmg-title="Mailingo" || {
      echo "⚠️ npx create-dmg 异常，降级到原生 hdiutil..."
      FALLBACK_HDIUTIL=1
    }
else
  FALLBACK_HDIUTIL=1
fi

if [ "${FALLBACK_HDIUTIL:-0}" -eq 1 ]; then
  echo "💿 使用原生 hdiutil 制作基础 DMG 镜像..."
  STAGING_DIR="$(mktemp -d -t mailingo-dmg-XXXXXX)"
  trap 'rm -rf "$STAGING_DIR"' EXIT
  
  ditto "$APP_PATH" "$STAGING_DIR/Mailingo.app"
  ln -s /Applications "$STAGING_DIR/Applications"
  
  TEMP_DMG="$(mktemp -t mailingo-out-XXXXXX).dmg"
  rm -f "$DMG_PATH" "$TEMP_DMG"
  hdiutil create \
    -volname "Mailingo" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$TEMP_DMG"
  mv -f "$TEMP_DMG" "$DMG_PATH"
fi

# 4. 生成 ZIP（作为备选下载包）
echo "🗜️ 制作 ZIP 压缩包 ($ZIP_PATH)..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# 5. 输出结果与 SHA256 校验和
echo ""
echo "✅ 打包完成！生成分发文件："
ls -lh "$DMG_PATH" "$ZIP_PATH"
echo ""
echo "🔐 SHA-256 校验和："
shasum -a 256 "$DMG_PATH" "$ZIP_PATH"
