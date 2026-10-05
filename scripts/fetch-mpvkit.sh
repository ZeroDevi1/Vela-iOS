#!/usr/bin/env bash
# 下载 MPVKit 1.0.0（LGPL）所需的预编译 xcframework 到 Packages/MPVKitLocal/Frameworks，并按清单校验 sha256。
#
# 为什么不用 SwiftPM 直接拉取：部分网络环境（代理 / TUN）下 SwiftPM 的二进制下载器会卡住，而 curl 正常。
# 文件较大（数百 MB），不入库；首次构建前或升级 MPVKit 时执行一次：
#   ./scripts/fetch-mpvkit.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="Packages/MPVKitLocal/Frameworks"
mkdir -p "$DEST"

while read -r name url checksum; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ -d "$DEST/$name.xcframework" ]]; then
    echo "✓ $name（已存在）"
    continue
  fi
  zip="$DEST/$name.xcframework.zip"
  echo "↓ $name"
  curl -fL --retry 3 -o "$zip" "$url"
  actual=$(shasum -a 256 "$zip" | awk '{print $1}')
  if [[ "$actual" != "$checksum" ]]; then
    echo "✗ $name 校验失败：期望 $checksum，实际 $actual" >&2
    rm -f "$zip"
    exit 1
  fi
  unzip -q -o "$zip" -d "$DEST"
  rm -f "$zip"
done < scripts/mpvkit-binaries.txt
echo "完成：$(du -sh "$DEST" | awk '{print $1}')"
