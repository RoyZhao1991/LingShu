#!/usr/bin/env bash
# 签名 + 安装灵枢虚拟麦克风 HAL 驱动 + 重启 coreaudiod。需 sudo。
# 用法:sudo bash install-driver.sh ["Developer ID Application: 你的名字 (TEAMID)"]
# 不给签名身份则 ad-hoc 签名(开发期、本机 SIP 允许时可用)。
set -euo pipefail
cd "$(dirname "$0")"

NAME="LingShuAudioDriver"
DRIVER="build/${NAME}.driver"
DEST="/Library/Audio/Plug-Ins/HAL"
SIGN_ID="${1:--}"   # 默认 ad-hoc

[ -d "$DRIVER" ] || { echo "找不到 $DRIVER,先 bash build-driver.sh"; exit 1; }

echo "==> 签名($SIGN_ID)"
codesign --force --sign "$SIGN_ID" --timestamp=none --deep "$DRIVER"

echo "==> 安装到 $DEST(需 sudo)"
mkdir -p "$DEST"
rm -rf "$DEST/${NAME}.driver"
cp -R "$DRIVER" "$DEST/"

echo "==> 重启 coreaudiod 使其加载"
killall coreaudiod 2>/dev/null || true
sleep 2
echo "完成。打开『音频 MIDI 设置』应能看到『灵枢虚拟麦克风』。会议 App 麦克风选它即可。"
