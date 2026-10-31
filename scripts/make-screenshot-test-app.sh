#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-policy.sh
rubick_require_signing_identity
RUBICK_TEST_BUILD="${RUBICK_TEST_BUILD:-$PWD/.build-screenshot-test}"
export CLANG_MODULE_CACHE_PATH="$RUBICK_TEST_BUILD/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$RUBICK_TEST_BUILD/module-cache"
swift build --disable-sandbox --scratch-path "$RUBICK_TEST_BUILD" --build-system native
RUBICK_TEST_BIN=$(swift build --disable-sandbox --scratch-path "$RUBICK_TEST_BUILD" --build-system native --show-bin-path)
# Assemble outside synced Desktop folders: File Provider may reattach FinderInfo after xattr cleanup.
RUBICK_TEST_APP="${RUBICK_TEST_APP:-${TMPDIR:-/tmp}/rubick-package/拉比克.app}"
mkdir -p "$RUBICK_TEST_APP/Contents/MacOS" "$RUBICK_TEST_APP/Contents/Resources"
if [ -f "$RUBICK_TEST_APP/Contents/MacOS/ClipboardTool" ]; then
    mv "$RUBICK_TEST_APP/Contents/MacOS/ClipboardTool" "$RUBICK_TEST_BUILD/legacy-ClipboardTool-$(date +%Y%m%d%H%M%S)"
fi
cp "$RUBICK_TEST_BIN/ClipboardTool" "$RUBICK_TEST_APP/Contents/MacOS/RubickScreenshotTest"
cp Resources/Info.plist "$RUBICK_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.rubick.screenshot-test' "$RUBICK_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName 拉比克' "$RUBICK_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 拉比克' "$RUBICK_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable RubickScreenshotTest' "$RUBICK_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 2.0.0-test7' "$RUBICK_TEST_APP/Contents/Info.plist"
RUBICK_BUILD_STAMP=$(date +%Y%m%d%H%M%S)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RUBICK_BUILD_STAMP" "$RUBICK_TEST_APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$RUBICK_TEST_APP/Contents/Resources/"; fi
if [ -f Resources/menuGlyph.png ]; then cp Resources/menuGlyph.png "$RUBICK_TEST_APP/Contents/Resources/"; fi
xattr -cr "$RUBICK_TEST_APP"
rubick_sign_app "$RUBICK_TEST_APP"
codesign --verify --strict "$RUBICK_TEST_APP"
echo "$RUBICK_TEST_APP"
