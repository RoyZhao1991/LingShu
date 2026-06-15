#!/usr/bin/env bash
# 用 SwiftPM 构建并打成真正的 灵枢.app（带 Info.plist、图标、ad-hoc 签名）。
# 裸可执行文件没有 bundle：TCC 不认隐私用途说明、Dock 也没有图标。必须打成 .app 运行。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="${1:-debug}"
APP_NAME="灵枢"
BUNDLE_ID="com.zhaoroy.lingshu"
APP_DIR="$ROOT_DIR/dist/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" >/dev/null
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"
[ -f "$BIN_PATH" ] || { echo "executable not found: $BIN_PATH"; exit 1; }

echo "==> assembling bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"

# 图标：从 appiconset 合成 .icns
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
ICON_SRC="$ROOT_DIR/Assets.xcassets/AppIcon.appiconset"
sips -z 16 16     "$ICON_SRC/lingshu-16.png"   --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$ICON_SRC/lingshu-32.png"   --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$ICON_SRC/lingshu-32.png"   --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$ICON_SRC/lingshu-64.png"   --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$ICON_SRC/lingshu-128.png"  --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$ICON_SRC/lingshu-256.png"  --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_SRC/lingshu-256.png"  --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$ICON_SRC/lingshu-512.png"  --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_SRC/lingshu-512.png"  --out "$ICONSET/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$ICON_SRC/lingshu-1024.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"

if [ -d "$ROOT_DIR/Resources/RuntimeConfig" ]; then
  echo "==> copying runtime config"
  mkdir -p "$RES_DIR/RuntimeConfig"
  ditto "$ROOT_DIR/Resources/RuntimeConfig" "$RES_DIR/RuntimeConfig"
fi

# DesignKB(自进化 PPT 设计知识库:生成器 + 配色/版式/字体 + rubric + Lucide 图标)随包交付。
if [ -d "$ROOT_DIR/Resources/DesignKB" ]; then
  echo "==> copying DesignKB"
  mkdir -p "$RES_DIR/DesignKB"
  ditto "$ROOT_DIR/Resources/DesignKB" "$RES_DIR/DesignKB"
fi

# 灵枢虚拟麦克风 HAL 驱动:随包交付,运行时由灵枢自安装(一次授权),不需用户手动操作。
if [ -d "$ROOT_DIR/Drivers/LingShuAudioDriver" ]; then
  echo "==> building + bundling 灵枢虚拟麦克风驱动"
  if bash "$ROOT_DIR/Drivers/LingShuAudioDriver/build-driver.sh" >/dev/null 2>&1 \
     && [ -d "$ROOT_DIR/Drivers/LingShuAudioDriver/build/LingShuAudioDriver.driver" ]; then
    ditto "$ROOT_DIR/Drivers/LingShuAudioDriver/build/LingShuAudioDriver.driver" "$RES_DIR/LingShuAudioDriver.driver"
  else
    echo "   (驱动编译跳过/失败——虚拟麦后续在本机完善;不阻塞 app 构建)"
  fi
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>灵枢</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>灵枢</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key><string>用于视觉解析，让灵枢读取摄像头画面并形成实时观察。</string>
    <key>NSMicrophoneUsageDescription</key><string>用于语音输入，将你的语音转换为文字指令。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>用于将语音识别为灵枢可处理的文字指令。</string>
</dict>
</plist>
PLIST

# 稳定签名身份让 TCC 授权（屏幕录制/麦克风等）可持久、重建不丢；ad-hoc 做不到。
# 默认用本机的 Apple Development 证书，可用 LINGSHU_SIGN_IDENTITY 覆盖；缺证书时回退 ad-hoc。
SIGN_IDENTITY="${LINGSHU_SIGN_IDENTITY:-Apple Development: Yang Zhao (N69MT44KA3)}"
DRIVER_BUNDLE="$RES_DIR/LingShuAudioDriver.driver"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> code signing ($SIGN_IDENTITY)"
  # 关键:HAL 驱动必须**单独**用同一身份签——`--deep` 不会遍历 Contents/Resources 里的 .driver
  # (它只签 Frameworks/PlugIns 等常规嵌套位置),漏签会让驱动是 ad-hoc → coreaudiod 静默拒载、设备不出现。
  # 不给驱动套 app 的相机/麦克风 entitlements(HAL 插件不需要);带安全时戳(离线则回退无时戳)。
  if [ -d "$DRIVER_BUNDLE" ]; then
    echo "   ==> signing nested HAL driver ($SIGN_IDENTITY)"
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$DRIVER_BUNDLE" 2>/dev/null \
      || codesign --force --sign "$SIGN_IDENTITY" --options runtime "$DRIVER_BUNDLE"

    # 公证(关键!):实测 coreaudiod **只加载已公证的 HAL 插件**——Developer ID 签名还不够,
    # 未公证驱动 `spctl` 判 "Unnotarized Developer ID → rejected",coreaudiod 静默拒载、设备不出现。
    # 提供凭据才执行(否则跳过并提示):LINGSHU_NOTARY_PROFILE(notarytool keychain profile),
    # 或 LINGSHU_APPLE_ID + LINGSHU_APPLE_TEAM_ID + LINGSHU_APPLE_APP_PW(app 专用密码)。
    # 顺序:先签驱动→公证+staple 驱动→**最后**再签 app(让 app seal 已 staple 的驱动,不破坏其票)。
    NOTARY_ARGS=""
    if [ -n "$LINGSHU_NOTARY_PROFILE" ]; then
      NOTARY_ARGS="--keychain-profile $LINGSHU_NOTARY_PROFILE"
    elif [ -n "$LINGSHU_APPLE_ID" ] && [ -n "$LINGSHU_APPLE_APP_PW" ] && [ -n "$LINGSHU_APPLE_TEAM_ID" ]; then
      NOTARY_ARGS="--apple-id $LINGSHU_APPLE_ID --password $LINGSHU_APPLE_APP_PW --team-id $LINGSHU_APPLE_TEAM_ID"
    fi
    if [ -d "$DRIVER_BUNDLE" ] && [ -n "$NOTARY_ARGS" ] && [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
      echo "   ==> notarizing HAL driver (notarytool submit --wait)"
      NZIP="$(mktemp -d)/LingShuAudioDriver.zip"
      ditto -c -k --keepParent "$DRIVER_BUNDLE" "$NZIP"
      if xcrun notarytool submit "$NZIP" $NOTARY_ARGS --wait; then
        xcrun stapler staple "$DRIVER_BUNDLE" && echo "   ==> driver notarized + stapled ✅" \
          || echo "   ==> staple 失败(公证可能仍在传播,可稍后手动 stapler staple)"
      else
        echo "   ==> 公证失败/超时——驱动未公证,coreaudiod 仍不会加载(见 notarytool 输出)"
      fi
    elif [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
      echo "   ==> (跳过公证:未提供 LINGSHU_NOTARY_PROFILE 或 Apple ID 凭据;coreaudiod 需**公证后**才加载驱动——见 Drivers/LingShuAudioDriver/README)"
    fi
  fi
  # app 最后签,seal 住已 staple 的驱动。
  codesign --force --deep --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT_DIR/LingShu.entitlements" \
    --options runtime \
    "$APP_DIR"
else
  echo "==> code signing (ad-hoc 回退；未找到身份「$SIGN_IDENTITY」)"
  [ -d "$DRIVER_BUNDLE" ] && codesign --force --sign - --options runtime "$DRIVER_BUNDLE" 2>/dev/null || true
  codesign --force --deep --sign - \
    --entitlements "$ROOT_DIR/LingShu.entitlements" \
    --options runtime \
    "$APP_DIR" 2>/dev/null || \
  codesign --force --deep --sign - \
    --entitlements "$ROOT_DIR/LingShu.entitlements" \
    "$APP_DIR"
fi

echo "$APP_DIR"
