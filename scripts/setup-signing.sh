#!/bin/bash
# 一次性脚本：生成固定代码签名证书「ClipboardTool Dev」
# 解决 ad-hoc 签名每次构建指纹变化 → 辅助功能（自动粘贴）授权失效的问题
# 只需在本机运行一次；之后 make-app.sh 会自动用该身份签名，授权永久有效。
set -e
cd "$(dirname "$0")/.."

CERT_DIR=".signing"
mkdir -p "$CERT_DIR"
CERT="$CERT_DIR/cbt-dev-cert.pem"
P12="$CERT_DIR/cbt-dev.p12"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "ClipboardTool Dev"; then
  echo "==> 已存在「ClipboardTool Dev」签名身份，跳过生成"
else
  echo "==> 1/4 生成自签名证书（10 年有效）"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/cbt-key.pem" -out "$CERT" -days 3650 \
    -subj "/CN=ClipboardTool Dev"

  echo "==> 2/4 打包为 p12 并导入钥匙串（密码 cbtdev，仅本地开发用）"
  openssl pkcs12 -export -inkey "$CERT_DIR/cbt-key.pem" -in "$CERT" \
    -out "$P12" -passout pass:cbtdev
  security import "$P12" -k ~/Library/Keychains/login.keychain-db -P cbtdev -T /usr/bin/codesign

  echo "==> 3/4 设置信任"
  security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db "$CERT"
fi

echo "==> 4/4 验证"
security find-identity -v -p codesigning | grep "ClipboardTool Dev" && \
  echo "==> 完成！接下来：① ./scripts/make-app.sh 重新打包；② 打开新包；③ 系统设置→隐私与安全性→辅助功能：先选中旧的「剪贴板工具」条目按 − 删除，再按 + 添加新包（或等它弹窗）；④ 重启应用即可自动粘贴。"
