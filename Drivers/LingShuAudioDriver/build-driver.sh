#!/usr/bin/env bash
# 编译灵枢虚拟麦克风 HAL 驱动为 .driver bundle。需 Xcode 命令行工具(clang)。
set -euo pipefail
cd "$(dirname "$0")"

NAME="LingShuAudioDriver"
OUT="build/${NAME}.driver"
rm -rf build && mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"

echo "==> clang 编译 AudioServerPlugIn"
clang -bundle -arch arm64 -arch x86_64 \
  -mmacosx-version-min=11.0 \
  -framework CoreFoundation -framework CoreAudio \
  -o "${OUT}/Contents/MacOS/${NAME}" \
  "${NAME}.c"

cp Info.plist "${OUT}/Contents/Info.plist"
echo "==> 产出:${OUT}"
echo "下一步:sudo bash install-driver.sh  (签名 + 安装 + 重启 coreaudiod)"
