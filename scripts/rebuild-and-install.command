#!/bin/bash
# 拉比克：一键重建 + 安装
# 签名优先用钥匙串里现成的 Apple Development 证书（授权持久）；
# 两者皆无时才创建自签证书「ClipboardTool Dev」（会弹一次密码框）
set -e
cd "$(dirname "$0")/.."

if ! security find-identity -v 2>/dev/null | grep -qE "Apple Development|ClipboardTool Dev"; then
  echo "==> 首次运行：创建固定签名证书「ClipboardTool Dev」（会弹一次密码框）…"
  ./scripts/setup-signing.sh
fi

echo "==> 构建通用版并用固定证书签名…"
./scripts/make-app.sh --universal

echo "==> 安装到 /Applications 并启动…"
./scripts/reinstall.command

echo ""
echo "✅ 完成。此后每次更新只需再双击本脚本，辅助功能/屏幕录制授权不会失效。"
