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
# 签名身份优先级：Apple Development（真实证书，授权最稳）→ 本地自签 ClipboardTool Dev → ad-hoc
# 同一证书签名 = Designated Requirement 稳定 = TCC 授权（辅助功能/屏幕录制）跨构建持久
# RUBICK_SIGN=adhoc 可强制跳过身份签名（如夜间钥匙串授权通道挂起时）
if [ "${RUBICK_SIGN:-}" != "adhoc" ]; then
  IDENTITY=$(security find-identity -v 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
  if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v 2>/dev/null | grep -o '"ClipboardTool Dev"' | head -1 | tr -d '"')
  fi
fi

if [ -n "$IDENTITY" ]; then
  # 签名前清扩展属性：仓库文件携带的 Finder 属性会让 codesign 报 detritus 拒签
  xattr -cr "$APP"
  # 后台会话可能弹不出 Apple 证书的私钥授权框（errSecInternalComponent）——失败自动降级自签证书
  if codesign --force --deep -s "$IDENTITY" "$APP" 2>/dev/null; then
    echo "==> 已用固定身份「$IDENTITY」签名（辅助功能授权可持续生效）"
  elif [ "$IDENTITY" != "ClipboardTool Dev" ] && security find-identity -v 2>/dev/null | grep -q "ClipboardTool Dev"; then
    codesign --force --deep -s "ClipboardTool Dev" "$APP"
    echo "==> Apple 证书签名失败（后台会话无法弹授权框），已改用「ClipboardTool Dev」自签（同为固定身份，授权持久）"
  else
    echo "==> ⚠ 「$IDENTITY」签名失败且无降级身份，改用 ad-hoc（重装后需重新授权）"
    codesign --force --deep -s - "$APP"
  fi
else
  codesign --force --deep -s - "$APP"
  echo ""
  echo "==> ⚠ 当前为 ad-hoc 签名：每次重新构建后，辅助功能（自动粘贴）授权会失效。"
  echo "==> 建议先运行一次 ./scripts/setup-signing.sh 建立固定签名，再重新打包。"
fi

echo "==> 已生成 $APP"
echo "    双击即可运行；或将应用拖入「应用程序」文件夹。"
