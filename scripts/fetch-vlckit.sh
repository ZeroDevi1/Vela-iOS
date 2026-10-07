#!/usr/bin/env bash
# 拉取播放内核 VLCKit（LGPL-2.1，与本项目 GPLv3 兼容）的官方预编译包到 Packages/VLCKit。
# 使用 4.0 测试版：iOS / 模拟器 arm64 / macOS 同一个 xcframework，且原生支持画中画（3.x 没有，且 iOS 模拟器缺 arm64）。
#
# 来源为 VideoLAN 官方 CocoaPods 发布目录（download.videolan.org）。压缩包约 522 MB，解压后体积较大，不入库；
# 首次构建前或升级版本时执行一次：
#   ./scripts/fetch-vlckit.sh
# 解压后在 Packages/VLCKit 生成一个本地 SwiftPM 包（二进制目标），供 VelaKit 以路径依赖引用。
set -euo pipefail
cd "$(dirname "$0")/.."

# 固定版本：升级时同时修改这里与 SHA256，并验证 iOS / macOS 构建与播放。
VLCKIT_ARCHIVE="VLCKit-4.0.0a19-d7597c1706-85a537d69.tar.xz"
VLCKIT_URL="https://download.videolan.org/pub/cocoapods/unstable/$VLCKIT_ARCHIVE"
DEST="Packages/VLCKit"
STAMP="$DEST/.version"

if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$VLCKIT_ARCHIVE" ]]; then
  echo "✓ $DEST（已是 $VLCKIT_ARCHIVE）"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "↓ $VLCKIT_URL"
curl -fsSL --retry 3 -o "$tmp/$VLCKIT_ARCHIVE" "$VLCKIT_URL"
tar -xJf "$tmp/$VLCKIT_ARCHIVE" -C "$tmp"
framework="$(find "$tmp" -maxdepth 3 -name 'VLCKit.xcframework' -type d | head -1)"
if [[ -z "$framework" ]]; then
  echo "压缩包中没有 VLCKit.xcframework，目录结构：" >&2
  find "$tmp" -maxdepth 3 >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
mv "$framework" "$DEST/VLCKit.xcframework"
cat > "$DEST/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
// 由 scripts/fetch-vlckit.sh 生成：把 VideoLAN 官方的 VLCKit.xcframework 包装为本地 SwiftPM 二进制包。
import PackageDescription

let package = Package(
    name: "VLCKit",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .visionOS(.v1)],
    products: [.library(name: "VLCKit", targets: ["VLCKit"])],
    targets: [.binaryTarget(name: "VLCKit", path: "VLCKit.xcframework")]
)
SWIFT
echo "$VLCKIT_ARCHIVE" > "$STAMP"
echo "✓ $DEST"
