#!/bin/bash
# 构建并打包为 .app
# 必须显式指定固定签名身份，并验证与已安装版本的授权身份一致。
set -e
cd "$(dirname "$0")/.."
source scripts/signing-policy.sh
rubick_require_signing_identity

UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

# 构建环境：兼容普通终端与受限沙箱环境
export TMPDIR="${TMPDIR:-$PWD/.tmp}"
mkdir -p "$TMPDIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$TMPDIR/modulecache"
EXTRA="--disable-sandbox"

if [ "$UNIVERSAL" = "1" ]; then
  echo "==> swift build -c release (arm64 + x86_64)"
  # --build-system native：Xcode 27 起 SwiftPM 默认 swiftbuild，其产物路径与下方
  # lipo 读取的 .build/<triple>/release 不一致，会打出陈旧切片（2026-09-28 事故）
  swift build --arch arm64 -c release $EXTRA --build-system native
  swift build --arch x86_64 -c release $EXTRA --build-system native
else
  echo "==> swift build -c release"
  swift build -c release $EXTRA --build-system native
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
# Preserve the identity of the single installed app, including the historical test ID.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.rubick.screenshot-test' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName 拉比克' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 拉比克' "$APP/Contents/Info.plist"
mv "$APP/Contents/MacOS/ClipboardTool" "$APP/Contents/MacOS/RubickScreenshotTest"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable RubickScreenshotTest' "$APP/Contents/Info.plist"
cp Resources/menuGlyph.png "$APP/Contents/Resources/" 2>/dev/null || true
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
elif [ -f build/AppIcon.icns ]; then
  cp build/AppIcon.icns "$APP/Contents/Resources/"
else
  echo "（未找到 AppIcon.icns，先运行图标生成流程；可暂时无图标）"
fi

# Never silently change the signing identity of an installed application.
# 仓库位于 iCloud FileProvider 同步区：build/ 内文件会被系统反复补写 FinderInfo，
# codesign 永远报 "detritus not allowed"。在同步区外完成签名与校验再拷回。
SIGN_STAGE="$(mktemp -d /tmp/rubick-sign.XXXXXX)"
trap 'rm -rf "$SIGN_STAGE"' EXIT
cp -R "$APP" "$SIGN_STAGE/app"
xattr -cr "$SIGN_STAGE/app"
rubick_sign_app "$SIGN_STAGE/app"
codesign --verify --strict "$SIGN_STAGE/app"
rm -rf "$APP"
cp -R "$SIGN_STAGE/app" "$APP"
xattr -cr "$APP"
codesign --verify --strict "$APP"

echo "==> 已生成 $APP"
echo "    双击即可运行；或将应用拖入「应用程序」文件夹。"
