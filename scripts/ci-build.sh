#!/usr/bin/env bash
# 与 GitHub Actions 共用的 Release 构建入口；iOS 产出供自行签名的通用 IPA，macOS 使用 ad-hoc 签名。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-}"
case "$PLATFORM" in
  ios|macos) ;;
  *) echo "用法：bash scripts/ci-build.sh <ios|macos>" >&2; exit 2 ;;
esac

BUILD_DIR="${VELA_CI_BUILD_ROOT:-$ROOT/build/ci}/$PLATFORM"
mkdir -p "$BUILD_DIR"
COMMON=(
  -project "$ROOT/Vela.xcodeproj"
  -scheme Vela
  -configuration Release
  -derivedDataPath "$BUILD_DIR/DerivedData"
  -archivePath "$BUILD_DIR/Vela.xcarchive"
  -resultBundlePath "$BUILD_DIR/Build.xcresult"
)
APP="$BUILD_DIR/Vela.xcarchive/Products/Applications/Vela.app"

case "$PLATFORM" in
  ios)
    xcodebuild "${COMMON[@]}" \
      -destination 'generic/platform=iOS' \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
      archive 2>&1 | tee "$BUILD_DIR/build.log"

    # 检查最终产物，确保 IPA 同时支持 iPhone（1）与 iPad（2）。
    python3 - "$APP/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    families = plistlib.load(stream).get("UIDeviceFamily", [])
if set(families) != {1, 2}:
    sys.exit(f"IPA 未同时支持 iPhone / iPad：UIDeviceFamily={families}")
PY
    mkdir -p "$BUILD_DIR/Payload"
    ditto "$APP" "$BUILD_DIR/Payload/Vela.app"
    ditto -c -k --keepParent "$BUILD_DIR/Payload" "$BUILD_DIR/Vela-iOS-iPadOS-unsigned.ipa"
    ;;
  macos)
    # 无分发证书时统一使用 ad-hoc 签名；关闭 Hardened Runtime，避免第三方动态框架的 Team ID 校验。
    xcodebuild "${COMMON[@]}" \
      -destination 'generic/platform=macOS' \
      'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
      ENABLE_HARDENED_RUNTIME=NO \
      archive 2>&1 | tee "$BUILD_DIR/build.log"

    ARCHITECTURES=" $(lipo -archs "$APP/Contents/MacOS/Vela") "
    if [[ "$ARCHITECTURES" != *" arm64 "* || "$ARCHITECTURES" != *" x86_64 "* ]]; then
      echo "macOS 产物缺少通用架构：$ARCHITECTURES" >&2
      exit 1
    fi
    codesign --verify --deep --strict "$APP"
    # 先打 ZIP 再上传，保留 app 内的执行权限、框架符号链接与包结构。
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD_DIR/Vela-macOS-universal.zip"
    ;;
esac
