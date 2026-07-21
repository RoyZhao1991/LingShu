#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/LingShu.app"
DERIVED_DATA="$ROOT_DIR/XcodeAppDerived"
CONFIGURATION="${1:-Release}"

cd "$ROOT_DIR"

xcodebuild \
  -project LingShuApp.xcodeproj \
  -scheme LingShu \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build

rm -rf "$APP_DIR"
ditto "$DERIVED_DATA/Build/Products/$CONFIGURATION/LingShu.app" "$APP_DIR"

if [ -d "$ROOT_DIR/Resources/RuntimeConfig" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/RuntimeConfig"
  ditto "$ROOT_DIR/Resources/RuntimeConfig" "$APP_DIR/Contents/Resources/RuntimeConfig"
fi

mkdir -p "$APP_DIR/Contents/Frameworks"
RUNTIME_CONFIGURATION="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
bash "$ROOT_DIR/Scripts/build-grok-runtime.sh" "$RUNTIME_CONFIGURATION" "$APP_DIR/Contents/Frameworks"

xattr -cr "$APP_DIR" || true

# Xcode signs its product before this script adds the embedded Runtime. Preserve
# that identity (or fall back to ad-hoc) and seal the final bundle again.
SIGN_IDENTITY="$(codesign -dvv "$APP_DIR" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/Frameworks/liblingshu_grok_runtime.dylib"
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT_DIR/LingShu.entitlements" \
  --options runtime \
  "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$APP_DIR" >/dev/null 2>&1 || true

echo "$APP_DIR"
