#!/bin/bash
# 拉比克一键重装：退出旧版 → 用最新构建覆盖 /Applications → 清理属性 → 重新签名 → 启动
set -e
cd "$(dirname "$0")/.."

APP_SRC="build/拉比克.app"
APP_DST="/Applications/拉比克.app"

if [ ! -d "$APP_SRC" ]; then
  echo "❌ 未找到 $APP_SRC，请先运行 ./scripts/make-app.sh 构建最新版本。"
  exit 1
fi

echo "==> 退出正在运行的拉比克…"
osascript -e 'tell application "拉比克" to quit' 2>/dev/null || killall ClipboardTool 2>/dev/null || true
sleep 1

echo "==> 卸载旧版…"
rm -rf "$APP_DST"

echo "==> 安装新版本…"
ditto "$APP_SRC" "$APP_DST"
xattr -cr "$APP_DST" 2>/dev/null || true
codesign --force --deep -s - "$APP_DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DST"

echo "==> 启动拉比克…"
open "$APP_DST"

echo ""
echo "✅ 完成！版本：$(defaults read "$APP_DST/Contents/Info" CFBundleShortVersionString 2>/dev/null || plutil -extract CFBundleShortVersionString raw "$APP_DST/Contents/Info.plist")"
echo "⚠️  首次打开请到 系统设置 → 隐私与安全性 → 辅助功能 重新勾选「拉比克」（重装后自动粘贴授权会失效一次）。"
echo "（窗口吸附还需要「屏幕录制」权限，首次 ⌘⇧A 时会引导。）"
