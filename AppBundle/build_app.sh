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
xattr -cr "$APP_DIR" || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$APP_DIR" >/dev/null 2>&1 || true

echo "$APP_DIR"
