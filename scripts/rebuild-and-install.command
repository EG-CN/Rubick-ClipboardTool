#!/bin/bash
# 拉比克：一键重建 + 安装
# 签名优先用钥匙串里现成的 Apple Development 证书（授权持久）；
# 两者皆无时才创建自签证书「ClipboardTool Dev」（会弹一次密码框）
set -e
cd "$(dirname "$0")/.."

source scripts/signing-policy.sh
rubick_require_signing_identity

echo "==> 构建通用版并用固定证书签名…"
./scripts/make-app.sh --universal

echo "==> 安装到 /Applications 并启动…"
./scripts/reinstall.command

echo ""
echo "✅ 完成。此后每次更新只需再双击本脚本，更新前会验证签名身份一致；系统权限变化仍需按系统提示处理。"
