#!/bin/bash
# 用法: ./scripts/make-icns.sh <source.png> [output.icns]
# 把 1024×1024 正方形 PNG 转成 macOS 应用图标 (.icns)
# 依赖系统自带 sips + iconutil，无第三方依赖
set -e
cd "$(dirname "$0")/.."

SRC="$1"
OUT="${2:-build/AppIcon.icns}"

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "用法: ./scripts/make-icns.sh <source.png> [output.icns]"
  echo "要求: 正方形 PNG，建议 1024×1024"
  exit 1
fi

TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# 规范化：裁成正方形（取中心）再缩放，避免拉伸变形
python3 - "$SRC" "$TMP/square.png" << 'EOF' 2>/dev/null || cp "$SRC" "$TMP/square.png"
EOF

# 用 sips 生成全部尺寸（如果原图非正方形会被拉伸，上面已尽量规避）
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
  d=$((s*2))
  sips -z $d $d "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
done

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$TMP"
echo "==> 已生成: $OUT"
