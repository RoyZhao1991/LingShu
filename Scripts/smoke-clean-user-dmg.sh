#!/usr/bin/env bash
# Verify the public DMG from a disposable user domain without reading the maintainer's state.
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
hash -r

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG_PATH="${1:-}"
OUTPUT_PATH="${2:-$ROOT_DIR/dist/clean-user-smoke-result.json}"
PRODUCT_NAME="灵枢"

fail() {
  echo "error: $*" >&2
  exit 1
}

[ -n "$DMG_PATH" ] || fail "usage: $0 /path/to/notarized.dmg [result.json]"
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
[ -f "$DMG_PATH" ] || fail "DMG not found: $DMG_PATH"

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lingshu-clean-user-smoke.XXXXXX")"
MOUNT_POINT="$SMOKE_ROOT/mount"
INSTALL_DIR="$SMOKE_ROOT/Applications"
RESULT_PATH="$SMOKE_ROOT/result.json"
APP_LOG="$SMOKE_ROOT/app.log"
APP_PID=""
MOUNTED=0

cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [ "$MOUNTED" = "1" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

echo "==> validating notarized DMG"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

mkdir -p "$MOUNT_POINT" "$INSTALL_DIR" "$SMOKE_ROOT/tmp"
hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_POINT" >/dev/null
MOUNTED=1
[ -d "$MOUNT_POINT/$PRODUCT_NAME.app" ] || fail "DMG does not contain $PRODUCT_NAME.app"

echo "==> installing payload into disposable Applications"
ditto "$MOUNT_POINT/$PRODUCT_NAME.app" "$INSTALL_DIR/$PRODUCT_NAME.app"
APP_PATH="$INSTALL_DIR/$PRODUCT_NAME.app"
APP_BINARY="$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
[ -x "$APP_BINARY" ] || fail "installed app executable is missing"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "==> launching with isolated home, preferences, credentials, and temporary files"
env -i \
  PATH="$PATH" \
  LANG="en_US.UTF-8" \
  LC_ALL="en_US.UTF-8" \
  HOME="$SMOKE_ROOT" \
  CFFIXED_USER_HOME="$SMOKE_ROOT" \
  TMPDIR="$SMOKE_ROOT/tmp" \
  LINGSHU_CLEAN_USER_SMOKE=1 \
  LINGSHU_CLEAN_USER_ROOT="$SMOKE_ROOT" \
  LINGSHU_CLEAN_USER_RESULT="$RESULT_PATH" \
  LINGSHU_CLEAN_USER_SOURCE="notarized-dmg:$(basename "$DMG_PATH")" \
  "$APP_BINARY" >"$APP_LOG" 2>&1 &
APP_PID=$!

for _ in $(seq 1 120); do
  if [ -s "$RESULT_PATH" ]; then
    break
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    cat "$APP_LOG" >&2 || true
    fail "app exited before writing the smoke result"
  fi
  sleep 0.25
done

[ -s "$RESULT_PATH" ] || {
  cat "$APP_LOG" >&2 || true
  fail "app did not write a smoke result within 30 seconds"
}
kill -0 "$APP_PID" 2>/dev/null || fail "app was not alive after writing the smoke result"

plutil -replace checks.notarizedDMG -bool YES "$RESULT_PATH"
plutil -replace checks.installedPayloadSignature -bool YES "$RESULT_PATH"
plutil -replace checks.appAliveAfterResult -bool YES "$RESULT_PATH"

CHECKS=(
  notarizedDMG
  installedPayloadSignature
  appAliveAfterResult
  initialLanguageSelectionPresented
  brainSetupPresentedWithoutConfiguration
  applicationSupportIsolated
  preferencesIsolated
  keychainAccessDisabled
  taskHistoryInitiallyEmpty
  permissionServicesDisabled
  minimalDirectReplyCompleted
)

for key in "${CHECKS[@]}"; do
  value="$(plutil -extract "checks.$key" raw -o - "$RESULT_PATH" 2>/dev/null || true)"
  [ "$value" = "true" ] || fail "clean-user check failed: $key=$value"
done

mkdir -p "$(dirname "$OUTPUT_PATH")"
cp "$RESULT_PATH" "$OUTPUT_PATH"
chmod 0644 "$OUTPUT_PATH"

echo "==> clean-user smoke passed"
cat "$OUTPUT_PATH"
