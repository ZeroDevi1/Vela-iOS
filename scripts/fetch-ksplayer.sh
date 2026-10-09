#!/usr/bin/env bash
# 拉取第二播放内核 KSPlayer（GPL-3.0，与本项目 GPLv3 兼容）及其依赖 FFmpegKit 到 Packages/ 下的本地镜像。
#
# 为什么不用 SwiftPM 直接拉取：FFmpegKit 的预编译库随 git 仓库分发（约 1.4 GB），SwiftPM 会为每个
# DerivedData 目录各克隆一份；改为本地路径包后只下载一次。KSPlayer 的 Package.swift 被改写为引用本地
# FFmpegKit，其余源码不做修改。体积大，不入库；首次构建前或升级版本时执行一次：
#   ./scripts/fetch-ksplayer.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# 固定版本：升级时同时修改这里并验证构建与播放。
KSPLAYER_COMMIT="be7f60d3b94a0941c643fe8699113cfce4f08e83"
FFMPEGKIT_TAG="6.1.4"

fetch_commit() {
  local url=$1 dest=$2 commit=$3
  if [[ -d "$dest/.git" ]] && [[ "$(git -C "$dest" rev-parse HEAD)" == "$commit" ]]; then
    echo "✓ $dest（已是 ${commit:0:7}）"
    return
  fi
  rm -rf "$dest"
  git init -q "$dest"
  git -C "$dest" remote add origin "$url"
  git -C "$dest" fetch -q --depth 1 origin "$commit"
  git -C "$dest" checkout -q FETCH_HEAD
  echo "↓ $dest（${commit:0:7}）"
}

fetch_tag() {
  local url=$1 dest=$2 tag=$3
  if [[ -d "$dest/.git" ]] && git -C "$dest" describe --tags --exact-match >/dev/null 2>&1 \
    && [[ "$(git -C "$dest" describe --tags --exact-match)" == "$tag" ]]; then
    echo "✓ $dest（已是 $tag）"
    return
  fi
  rm -rf "$dest"
  git clone -q --depth 1 --branch "$tag" "$url" "$dest"
  echo "↓ $dest（$tag）"
}

fetch_tag https://github.com/kingslay/FFmpegKit.git Packages/FFmpegKit "$FFMPEGKIT_TAG"
fetch_commit https://github.com/kingslay/KSPlayer.git Packages/KSPlayer "$KSPLAYER_COMMIT"

# 依赖改为本地 FFmpegKit（幂等）。
manifest=Packages/KSPlayer/Package.swift
if grep -q 'github.com/kingslay/FFmpegKit.git' "$manifest"; then
  sed -i '' 's#\.package(url: "https://github.com/kingslay/FFmpegKit.git", from: "[^"]*")#.package(path: "../FFmpegKit")#' "$manifest"
fi
grep -q '.package(path: "../FFmpegKit")' "$manifest" || { echo "✗ 未能改写 $manifest 的 FFmpegKit 依赖" >&2; exit 1; }
# Vela 对 KSPlayer 的修正（见各补丁文件头部说明），按文件名顺序应用。幂等：已应用的补丁记录在
# .git/vela-applied-patches（「校验和 文件名」）。不能只靠 `git apply --reverse --check` 判断：后面的补丁改到前面补丁的
# 上下文时，前面的补丁在已打完的源码上反向检查会失败。补丁内容变了需重新拉取（删除 Packages/KSPlayer 后重跑）。
applied=Packages/KSPlayer/.git/vela-applied-patches
if [[ ! -f "$applied" ]] && ! git -C Packages/KSPlayer diff --quiet HEAD -- Sources; then
  echo "✗ Packages/KSPlayer 的源码已修改但没有补丁记录（旧版脚本打的补丁），删除该目录后重新执行本脚本" >&2
  exit 1
fi
touch "$applied"
for patch in scripts/ksplayer-patches/*.patch; do
  [[ -f "$patch" ]] || continue
  name=$(basename "$patch")
  sum=$(shasum "$patch" | cut -d' ' -f1)
  if grep -qx "$sum $name" "$applied"; then
    echo "✓ 已应用 $name"
  elif grep -q " $name\$" "$applied"; then
    echo "✗ $name 已修改，删除 Packages/KSPlayer 后重新执行本脚本" >&2
    exit 1
  else
    git -C Packages/KSPlayer apply "../../$patch"
    echo "$sum $name" >> "$applied"
    echo "↑ 应用 $name"
  fi
done
# FFmpegKit 的 macOS 切片是浅层框架包（Info.plist 在根目录），macOS 应用嵌入时校验要求
# Versions/A/Resources/Info.plist 的深层结构，否则构建报 "does not use shallow bundles"。转换为深层结构（幂等）。
for fw in Packages/FFmpegKit/Sources/*.xcframework/macos-*/*.framework; do
  [[ -f "$fw/Info.plist" ]] || continue
  name=$(basename "$fw" .framework)
  mkdir -p "$fw/Versions/A/Resources"
  mv "$fw/Info.plist" "$fw/Versions/A/Resources/"
  mv "$fw/$name" "$fw/Versions/A/"
  for dir in Headers Modules; do
    [[ -d "$fw/$dir" ]] && mv "$fw/$dir" "$fw/Versions/A/" && ln -s "Versions/Current/$dir" "$fw/$dir"
  done
  ln -s A "$fw/Versions/Current"
  ln -s "Versions/Current/$name" "$fw/$name"
  ln -s Versions/Current/Resources "$fw/Resources"
done

echo "完成："
du -sh Packages/FFmpegKit Packages/KSPlayer
