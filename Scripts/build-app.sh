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

echo "==> code signing (ad-hoc, with entitlements)"
codesign --force --deep --sign - \
  --entitlements "$ROOT_DIR/LingShu.entitlements" \
  --options runtime \
  "$APP_DIR" 2>/dev/null || \
codesign --force --deep --sign - \
  --entitlements "$ROOT_DIR/LingShu.entitlements" \
  "$APP_DIR"

echo "$APP_DIR"
