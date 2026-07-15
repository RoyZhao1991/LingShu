#!/usr/bin/env bash
# 用 SwiftPM 构建并打成真正的 灵枢.app（带 Info.plist、图标与签名）。
# 裸可执行文件没有 bundle：TCC 不认隐私用途说明、Dock 也没有图标。必须打成 .app 运行。
set -euo pipefail

# Keep ordinary developer builds flexible, but make direct distribution builds
# inherit the same trusted tool boundary as the website release script.
if [ "${LINGSHU_REQUIRE_DISTRIBUTION_SIGNING:-0}" = "1" ]; then
  PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  hash -r
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="${1:-debug}"
APP_NAME="灵枢"
BUNDLE_ID="${LINGSHU_BUNDLE_ID:-com.zhaoroy.LingShu}"
APP_VERSION="${LINGSHU_VERSION:-0.1.0}"
BUILD_NUMBER="${LINGSHU_BUILD_NUMBER:-1}"
STRICT_DISTRIBUTION="${LINGSHU_REQUIRE_DISTRIBUTION_SIGNING:-0}"
UNIVERSAL_BUILD="${LINGSHU_UNIVERSAL:-0}"
BUNDLE_SENSEVOICE="${LINGSHU_BUNDLE_SENSEVOICE:-1}"
BUNDLE_HAL_DRIVER="${LINGSHU_BUNDLE_HAL_DRIVER:-1}"
APP_DIR="$ROOT_DIR/dist/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || {
  echo "invalid LINGSHU_VERSION: $APP_VERSION (expected 1.2 or 1.2.3)" >&2
  exit 1
}
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "invalid LINGSHU_BUILD_NUMBER: $BUILD_NUMBER (expected an integer)" >&2
  exit 1
}
[[ "$BUNDLE_SENSEVOICE" =~ ^[01]$ ]] || {
  echo "invalid LINGSHU_BUNDLE_SENSEVOICE: $BUNDLE_SENSEVOICE (expected 0 or 1)" >&2
  exit 1
}
[[ "$BUNDLE_HAL_DRIVER" =~ ^[01]$ ]] || {
  echo "invalid LINGSHU_BUNDLE_HAL_DRIVER: $BUNDLE_HAL_DRIVER (expected 0 or 1)" >&2
  exit 1
}

if [ "$UNIVERSAL_BUILD" = "1" ]; then
  echo "==> swift build ($CONFIG, universal arm64 + x86_64)"
  UNIVERSAL_TMP="$(mktemp -d)"
  ARCH_BINARIES=()
  for ARCH in arm64 x86_64; do
    SCRATCH_PATH="$ROOT_DIR/.build/website-$CONFIG-$ARCH"
    TRIPLE="$ARCH-apple-macosx14.0"
    swift build -c "$CONFIG" --triple "$TRIPLE" --scratch-path "$SCRATCH_PATH" >/dev/null
    ARCH_BIN="$(swift build -c "$CONFIG" --triple "$TRIPLE" --scratch-path "$SCRATCH_PATH" --show-bin-path)/${APP_NAME}"
    [ -f "$ARCH_BIN" ] || { echo "executable not found: $ARCH_BIN" >&2; exit 1; }
    ARCH_BINARIES+=("$ARCH_BIN")
  done
  BIN_PATH="$UNIVERSAL_TMP/$APP_NAME"
  lipo -create "${ARCH_BINARIES[@]}" -output "$BIN_PATH"
else
  echo "==> swift build ($CONFIG)"
  swift build -c "$CONFIG" >/dev/null
  BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"
fi
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
  if [ "$STRICT_DISTRIBUTION" = "1" ] && [ "${LINGSHU_INCLUDE_PRIVATE_RUNTIME_CONFIG:-0}" != "1" ]; then
    echo "   ==> removing private runtime credentials from public distribution"
    find "$RES_DIR/RuntimeConfig" -type f \( \
      -name '*.token' -o \
      -name '*.secret' -o \
      -iname '*secrets*.plist' -o \
      -iname '*credentials*.json' \
    \) -delete
  fi
fi

# DesignKB(自进化 PPT 设计知识库:生成器 + 配色/版式/字体 + rubric + Lucide 图标)随包交付。
if [ -d "$ROOT_DIR/Resources/DesignKB" ]; then
  echo "==> copying DesignKB"
  mkdir -p "$RES_DIR/DesignKB"
  ditto "$ROOT_DIR/Resources/DesignKB" "$RES_DIR/DesignKB"
fi

# SenseVoice 是可选增强。开发构建默认保留历史行为；官网轻量包显式传 0，
# 避免构建时下载 280MB+ 可变依赖，也避免把可选模型强塞给只需要 Apple Speech 的用户。
if [ "$BUNDLE_SENSEVOICE" = "1" ]; then
  if [ ! -x "$ROOT_DIR/Models/SenseVoice/bin/sherpa-onnx-vad-microphone-offline-asr" ]; then
    echo "==> SenseVoice 未安装,自动安装(随灵枢一起交付)"
    bash "$ROOT_DIR/Scripts/install-sensevoice.sh" || echo "   (SenseVoice 安装失败/跳过——麦克风回退 Apple Speech;不阻塞构建)"
  fi
  if [ -d "$ROOT_DIR/Models/SenseVoice" ]; then
    echo "==> copying SenseVoice ASR"
    mkdir -p "$RES_DIR/Models/SenseVoice"
    ditto "$ROOT_DIR/Models/SenseVoice" "$RES_DIR/Models/SenseVoice"
  fi
else
  echo "==> omitting optional SenseVoice runtime (Apple Speech remains available)"
fi

# HAL 虚拟麦克风需要高权限安装且仍处实验阶段。官网首包默认不携带；
# 本地/full 构建可显式打开，能力代码在资源缺失时会如实降级。
if [ "$BUNDLE_HAL_DRIVER" = "1" ] && [ -d "$ROOT_DIR/Drivers/LingShuAudioDriver" ]; then
  echo "==> building + bundling 灵枢虚拟麦克风驱动"
  if bash "$ROOT_DIR/Drivers/LingShuAudioDriver/build-driver.sh" >/dev/null 2>&1 \
     && [ -d "$ROOT_DIR/Drivers/LingShuAudioDriver/build/LingShuAudioDriver.driver" ]; then
    ditto "$ROOT_DIR/Drivers/LingShuAudioDriver/build/LingShuAudioDriver.driver" "$RES_DIR/LingShuAudioDriver.driver"
  else
    if [ "$STRICT_DISTRIBUTION" = "1" ]; then
      echo "error: HAL driver build failed; refusing to create an incomplete distribution" >&2
      exit 1
    fi
    echo "   (驱动编译跳过/失败——虚拟麦后续在本机完善;不阻塞本地 app 构建)"
  fi
else
  echo "==> omitting experimental HAL virtual microphone driver"
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
    <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key><string>用于视觉解析，让灵枢读取摄像头画面并形成实时观察。</string>
    <key>NSLocationUsageDescription</key><string>用于获取当前所在城市，让灵枢知道你在哪、提供本地相关信息（如本地时间/天气）。仅按需读取、不留存。</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>用于获取当前所在城市，让灵枢知道你在哪、提供本地相关信息（如本地时间/天气）。仅按需读取、不留存。</string>
    <key>NSMicrophoneUsageDescription</key><string>用于语音输入，将你的语音转换为文字指令。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>用于将语音识别为灵枢可处理的文字指令。</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>用于通过蓝牙读取已配对 iPhone 的系统通知(ANCS)，汇聚为灵枢的一种感知。仅本地、只读。</string>
    <key>NSCalendarsUsageDescription</key><string>用于读取日历事件并汇聚为灵枢的待办感知。仅本地、只读。</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>用于读取日历事件并汇聚为灵枢的待办感知。仅本地、只读。</string>
    <key>NSRemindersUsageDescription</key><string>用于读取提醒事项并汇聚为灵枢的待办感知。仅本地、只读。</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>用于读取提醒事项并汇聚为灵枢的待办感知。仅本地、只读。</string>
    <key>NSLocalNetworkUsageDescription</key><string>用于发现局域网内的智能家居设备(HomeKit/AirPlay/Matter/Shelly 等)，让灵枢统一呈现并接入控制。仅本地。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_hap._tcp</string>
        <string>_airplay._tcp</string>
        <string>_raop._tcp</string>
        <string>_matter._tcp</string>
        <string>_matterc._udp</string>
        <string>_hue._tcp</string>
        <string>_shelly._tcp</string>
        <string>_http._tcp</string>
        <string>_googlecast._tcp</string>
        <string>_miio._udp</string>
    </array>
</dict>
</plist>
PLIST

# 稳定签名身份让 TCC 授权（屏幕录制/麦克风等）可持久、重建不丢；ad-hoc 做不到。
# 本地开发可回退 ad-hoc；官网发布必须显式启用 STRICT_DISTRIBUTION，并使用 Developer ID。
SIGN_IDENTITY="${LINGSHU_SIGN_IDENTITY:-Apple Development: Yang Zhao}"
DRIVER_BUNDLE="$RES_DIR/LingShuAudioDriver.driver"
if [ "$STRICT_DISTRIBUTION" = "1" ] && [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "error: website distribution requires a Developer ID Application identity" >&2
  exit 1
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_IDENTITY\""; then
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
    # 用 ${VAR:-} 默认空,避免 `set -u`(nounset)下未设这些环境变量就中断构建。
    NOTARY_ARGS=()
    if [ -n "${LINGSHU_NOTARY_PROFILE:-}" ]; then
      NOTARY_ARGS=(--keychain-profile "$LINGSHU_NOTARY_PROFILE")
    elif [ -n "${LINGSHU_APPLE_ID:-}" ] && [ -n "${LINGSHU_APPLE_APP_PW:-}" ] && [ -n "${LINGSHU_APPLE_TEAM_ID:-}" ]; then
      NOTARY_ARGS=(--apple-id "$LINGSHU_APPLE_ID" --password "$LINGSHU_APPLE_APP_PW" --team-id "$LINGSHU_APPLE_TEAM_ID")
    fi
    if [ -d "$DRIVER_BUNDLE" ] && [ "${#NOTARY_ARGS[@]}" -gt 0 ] && [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
      echo "   ==> notarizing HAL driver (notarytool submit --wait)"
      NZIP="$(mktemp -d)/LingShuAudioDriver.zip"
      ditto -c -k --keepParent "$DRIVER_BUNDLE" "$NZIP"
      if xcrun notarytool submit "$NZIP" "${NOTARY_ARGS[@]}" --wait; then
        if xcrun stapler staple "$DRIVER_BUNDLE"; then
          echo "   ==> driver notarized + stapled"
        elif [ "$STRICT_DISTRIBUTION" = "1" ]; then
          echo "error: HAL driver notarized but ticket stapling failed" >&2
          exit 1
        else
          echo "   ==> staple 失败(公证可能仍在传播,可稍后手动 stapler staple)"
        fi
      else
        if [ "$STRICT_DISTRIBUTION" = "1" ]; then
          echo "error: HAL driver notarization failed" >&2
          exit 1
        fi
        echo "   ==> 公证失败/超时——驱动未公证,coreaudiod 仍不会加载(见 notarytool 输出)"
      fi
    elif [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
      if [ "$STRICT_DISTRIBUTION" = "1" ]; then
        echo "error: HAL driver requires notarization credentials for website distribution" >&2
        exit 1
      fi
      echo "   ==> (跳过公证:未提供 LINGSHU_NOTARY_PROFILE 或 Apple ID 凭据;coreaudiod 需公证后才加载驱动)"
    fi
  fi
  # SenseVoice sherpa-onnx 二进制 + dylib 单独签(在 app 之前):它是被 Process 启的独立可执行。
  # Developer ID 公证要求每个独立 Mach-O 可执行文件都启用 Hardened Runtime。其依赖 dylib 已先用
  # 同一 Developer ID 身份签名，因此保持库校验并给主二进制加 --options runtime，不再沿用早期的无 runtime 规避。
  SV_DIR="$RES_DIR/Models/SenseVoice"
  if [ -d "$SV_DIR" ]; then
    echo "   ==> signing SenseVoice runtime ($SIGN_IDENTITY)"
    if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
      find "$SV_DIR/lib" -name '*.dylib' -exec codesign --force --sign "$SIGN_IDENTITY" --timestamp {} \;
      codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$SV_DIR/bin/sherpa-onnx-vad-microphone-offline-asr"
    else
      find "$SV_DIR/lib" -name '*.dylib' -exec codesign --force --sign "$SIGN_IDENTITY" {} \; 2>/dev/null || true
      codesign --force --sign "$SIGN_IDENTITY" "$SV_DIR/bin/sherpa-onnx-vad-microphone-offline-asr" 2>/dev/null || true
    fi
  fi
  # app 最后签,seal 住已 staple 的驱动。嵌套代码已逐层签名，发布签名禁止使用 --deep。
  APP_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --entitlements "$ROOT_DIR/LingShu.entitlements" --options runtime)
  if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
    APP_SIGN_ARGS+=(--timestamp)
  fi
  if ! codesign "${APP_SIGN_ARGS[@]}" "$APP_DIR"; then
    if [ "$STRICT_DISTRIBUTION" = "1" ]; then
      echo "error: distribution code signing failed" >&2
      exit 1
    fi
    codesign --force --sign "$SIGN_IDENTITY" \
      --entitlements "$ROOT_DIR/LingShu.entitlements" \
      --options runtime \
      "$APP_DIR"
  fi
else
  if [ "$STRICT_DISTRIBUTION" = "1" ]; then
    echo "error: signing identity not found in the login keychain: $SIGN_IDENTITY" >&2
    echo "Install a valid Developer ID Application certificate and retry." >&2
    exit 1
  fi
  echo "════════════════════════════════════════════════════════════════"
  echo "⚠️  警告:未找到稳定签名身份「${SIGN_IDENTITY}」→ 回退 ad-hoc 签名!"
  echo "⚠️  ad-hoc 的 designated requirement 是 cdhash、每次重建都变 → 系统的"
  echo "⚠️  辅助功能/屏幕录制等授权会失效(列表里 checkbox 看着开着、实际无效)。"
  echo "⚠️  修复:确保钥匙串里有「${SIGN_IDENTITY}」证书,或用 LINGSHU_SIGN_IDENTITY 指定稳定证书后重建。"
  echo "════════════════════════════════════════════════════════════════"
  [ -d "$DRIVER_BUNDLE" ] && codesign --force --sign - --options runtime "$DRIVER_BUNDLE" 2>/dev/null || true
  codesign --force --sign - \
    --entitlements "$ROOT_DIR/LingShu.entitlements" \
    --options runtime \
    "$APP_DIR" 2>/dev/null || \
  codesign --force --sign - \
    --entitlements "$ROOT_DIR/LingShu.entitlements" \
    "$APP_DIR"
fi

if [ "$STRICT_DISTRIBUTION" = "1" ]; then
  PRIVATE_CONFIG="$(find "$RES_DIR/RuntimeConfig" -type f \( \
    -name '*.token' -o \
    -name '*.secret' -o \
    -iname '*secrets*.plist' -o \
    -iname '*credentials*.json' \
  \) -print -quit 2>/dev/null || true)"
  if [ -n "$PRIVATE_CONFIG" ]; then
    echo "error: private runtime credential leaked into distribution: $PRIVATE_CONFIG" >&2
    exit 1
  fi
fi

codesign --verify --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
