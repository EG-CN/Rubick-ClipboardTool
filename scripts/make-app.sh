#!/bin/bash
# 构建并打包为 .app
# 优先使用固定签名身份「ClipboardTool Dev」（辅助功能授权可持续生效），
# 未设置时回退 ad-hoc 签名（每次构建授权会失效）。
set -e
cd "$(dirname "$0")/.."

UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

# 构建环境：兼容普通终端与受限沙箱环境
export TMPDIR="${TMPDIR:-$PWD/.tmp}"
mkdir -p "$TMPDIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$TMPDIR/modulecache"
EXTRA="--disable-sandbox"

if [ "$UNIVERSAL" = "1" ]; then
  echo "==> swift build -c release (arm64 + x86_64)"
  swift build --arch arm64 -c release $EXTRA
  swift build --arch x86_64 -c release $EXTRA
else
  echo "==> swift build -c release"
  swift build -c release $EXTRA
fi

APP="build/拉比克.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$UNIVERSAL" = "1" ]; then
  lipo -create .build/arm64-apple-macosx/release/ClipboardTool .build/x86_64-apple-macosx/release/ClipboardTool -output "$APP/Contents/MacOS/ClipboardTool"
else
  cp .build/release/ClipboardTool "$APP/Contents/MacOS/"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/menuGlyph.png "$APP/Contents/Resources/" 2>/dev/null || true
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
elif [ -f build/AppIcon.icns ]; then
  cp build/AppIcon.icns "$APP/Contents/Resources/"
else
  echo "（未找到 AppIcon.icns，先运行图标生成流程；可暂时无图标）"
fi

IDENTITY=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ClipboardTool Dev"; then
  IDENTITY="ClipboardTool Dev"
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --deep -s "$IDENTITY" "$APP"
  echo "==> 已用固定身份「ClipboardTool Dev」签名（辅助功能授权可持续生效）"
else
  codesign --force --deep -s - "$APP"
  echo ""
  echo "==> ⚠ 当前为 ad-hoc 签名：每次重新构建后，辅助功能（自动粘贴）授权会失效。"
  echo "==> 建议先运行一次 ./scripts/setup-signing.sh 建立固定签名，再重新打包。"
fi

echo "==> 已生成 $APP"
echo "    双击即可运行；或将应用拖入「应用程序」文件夹。"
