#!/bin/bash
# 拉比克：一键重建 + 安装（首次会创建固定签名证书，之后权限授权永久有效）
set -e
cd "$(dirname "$0")/.."

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "ClipboardTool Dev"; then
  echo "==> 首次运行：创建固定签名证书「ClipboardTool Dev」（会弹一次密码框）…"
  ./scripts/setup-signing.sh
fi

echo "==> 构建通用版并用固定证书签名…"
./scripts/make-app.sh --universal

echo "==> 安装到 /Applications 并启动…"
./scripts/reinstall.command

echo ""
echo "✅ 完成。此后每次更新只需再双击本脚本，辅助功能/屏幕录制授权不会失效。"
