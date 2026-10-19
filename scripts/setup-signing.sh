#!/bin/bash
# One-time local signing identity; trust is scoped to code signing.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
CERT_NAME="Rubick Local Signing"
PIN_FILE=".signing/identity.sha1"
mkdir -p .signing
if [ -f "$PIN_FILE" ]; then
  PIN=$(cat "$PIN_FILE")
  if security find-identity -v -p codesigning | grep -Fq "$PIN"; then
    echo "固定签名身份已存在。"
    exit 0
  fi
  echo "已固定的签名身份不可用，停止以避免生成不同证书。" >&2
  exit 1
fi
SIGN_DIR=$(mktemp -d /private/tmp/rubick-signing.XXXXXX)
trap 'rm -rf "$SIGN_DIR"' EXIT
cat > "$SIGN_DIR/cert.cnf" <<'CONF'
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=Rubick Local Signing
[extensions]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
CONF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 -config "$SIGN_DIR/cert.cnf" -keyout "$SIGN_DIR/key.pem" -out "$SIGN_DIR/cert.pem" 2> "$SIGN_DIR/generation.log" || { cat "$SIGN_DIR/generation.log" >&2; exit 1; }
P12_PASSWORD=$(/usr/bin/openssl rand -hex 24)
export P12_PASSWORD
/usr/bin/openssl pkcs12 -export -inkey "$SIGN_DIR/key.pem" -in "$SIGN_DIR/cert.pem" -out "$SIGN_DIR/identity.p12" -passout env:P12_PASSWORD -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
security import "$SIGN_DIR/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12_PASSWORD" -T /usr/bin/codesign
unset P12_PASSWORD
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$SIGN_DIR/cert.pem"
PIN=$(/usr/bin/openssl x509 -in "$SIGN_DIR/cert.pem" -fingerprint -sha1 -noout | sed 's/.*=//;s/://g')
security find-identity -v -p codesigning | grep -F "$PIN"
printf '%s\n' "$PIN" > "$PIN_FILE"
echo "固定本机签名已建立并固定指纹。"
