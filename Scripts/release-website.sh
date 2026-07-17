#!/usr/bin/env bash
# Build the public website release: universal app, Developer ID signing,
# Apple notarization, stapled DMG, checksum and machine-readable manifest.
set -euo pipefail

# Public release builds use only the Apple/system toolchain. This prevents a
# writable package-manager or user PATH entry from shadowing signing, Git,
# archive, checksum, or notarization commands.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
hash -r

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PRODUCT_NAME="灵枢"
VERSION="${LINGSHU_VERSION:-0.1.0}"
BUILD_NUMBER="${LINGSHU_BUILD_NUMBER:-1}"
TEAM_ID="${LINGSHU_APPLE_TEAM_ID:-KM7N84AC9Y}"
EXPECTED_CERT_SHA256="${LINGSHU_SIGN_CERT_SHA256:-8B15EC76661737C31CAB3AF508A50F923BD86FC4C7B8AF2313E0157FAA2D8D02}"
NOTARY_PROFILE="${LINGSHU_NOTARY_PROFILE:-lingshu-notary}"
BUNDLE_SENSEVOICE="${LINGSHU_BUNDLE_SENSEVOICE:-0}"
BUNDLE_HAL_DRIVER="${LINGSHU_BUNDLE_HAL_DRIVER:-0}"
ALLOW_DIRTY_RELEASE="${LINGSHU_ALLOW_DIRTY_RELEASE:-0}"
RELEASE_DIR="${LINGSHU_RELEASE_DIR:-$ROOT_DIR/dist/releases/$VERSION-$BUILD_NUMBER}"
APP_PATH="$ROOT_DIR/dist/$PRODUCT_NAME.app"
DMG_NAME="LingShu-$VERSION-$BUILD_NUMBER-macOS-universal.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
APP_NOTARY_LOG="$RELEASE_DIR/notarization-app.json"
DMG_NOTARY_LOG="$RELEASE_DIR/notarization-dmg.json"
MANIFEST_PATH="$RELEASE_DIR/release-manifest.json"

TMP_DIR="$(mktemp -d)"
MOUNT_POINT="$TMP_DIR/mount"
DMG_STAGE="$TMP_DIR/dmg-root"
MOUNTED=0

cleanup() {
  if [ "$MOUNTED" = "1" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "invalid version: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "invalid build number: $BUILD_NUMBER"
[[ "$BUNDLE_SENSEVOICE" =~ ^[01]$ ]] || fail "LINGSHU_BUNDLE_SENSEVOICE must be 0 or 1"
[[ "$BUNDLE_HAL_DRIVER" =~ ^[01]$ ]] || fail "LINGSHU_BUNDLE_HAL_DRIVER must be 0 or 1"
[[ "$ALLOW_DIRTY_RELEASE" =~ ^[01]$ ]] || fail "LINGSHU_ALLOW_DIRTY_RELEASE must be 0 or 1"

BUNDLED_SENSEVOICE_BOOL=false
BUNDLED_HAL_DRIVER_BOOL=false
[ "$BUNDLE_SENSEVOICE" = "1" ] && BUNDLED_SENSEVOICE_BOOL=true
[ "$BUNDLE_HAL_DRIVER" = "1" ] && BUNDLED_HAL_DRIVER_BOOL=true

SOURCE_REVISION="$(git rev-parse HEAD 2>/dev/null)" || fail "release source is not a Git checkout"
SOURCE_ARCHIVE_SHA256="$(git archive --format=tar "$SOURCE_REVISION" | shasum -a 256 | awk '{print $1}')"
SOURCE_DIRTY=false
if [ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
  SOURCE_DIRTY=true
fi
if [ "$SOURCE_DIRTY" = "true" ] && [ "$ALLOW_DIRTY_RELEASE" != "1" ]; then
  fail "working tree is not clean; commit the exact release source first (use LINGSHU_ALLOW_DIRTY_RELEASE=1 only for a local rehearsal)"
fi

IDENTITY="${LINGSHU_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' \
    | grep -F "($TEAM_ID)" \
    | sed -n '1p')"
fi

[ -n "$IDENTITY" ] || fail "no valid Developer ID Application certificate found in the login keychain"
[[ "$IDENTITY" == Developer\ ID\ Application:* ]] || fail "not a Developer ID Application identity: $IDENTITY"
[[ "$IDENTITY" == *"($TEAM_ID)"* ]] || fail "signing identity does not belong to expected team $TEAM_ID: $IDENTITY"
security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$IDENTITY\"" >/dev/null \
  || fail "signing identity is not currently valid: $IDENTITY"

CERTIFICATE_SHA256="$(security find-certificate -a -c "$IDENTITY" -Z 2>/dev/null \
  | sed -n 's/^SHA-256 hash: //p' \
  | sed -n '1p')"
[ -n "$CERTIFICATE_SHA256" ] || fail "could not read the signing certificate fingerprint: $IDENTITY"
[[ "$CERTIFICATE_SHA256" =~ ^[0-9A-F]{64}$ ]] || fail "invalid signing certificate fingerprint: $CERTIFICATE_SHA256"
[ "$CERTIFICATE_SHA256" = "$EXPECTED_CERT_SHA256" ] \
  || fail "signing certificate fingerprint mismatch: expected $EXPECTED_CERT_SHA256, got $CERTIFICATE_SHA256"

SIGNING_PROBE="$TMP_DIR/signing-probe"
SIGNING_PROBE_LOG="$TMP_DIR/signing-probe.log"
cp /usr/bin/true "$SIGNING_PROBE"
if ! codesign --force --sign "$IDENTITY" --options runtime \
  "$SIGNING_PROBE" 2>"$SIGNING_PROBE_LOG"; then
  cat "$SIGNING_PROBE_LOG" >&2
  fail "Developer ID private key is not usable; unlock the login keychain and allow codesign access to the certificate's private key"
fi

cp /usr/bin/true "$SIGNING_PROBE"
if ! codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  "$SIGNING_PROBE" 2>"$SIGNING_PROBE_LOG"; then
  cat "$SIGNING_PROBE_LOG" >&2
  fail "Developer ID timestamp signing failed; check access to Apple's timestamp service and temporarily bypass incompatible local proxies"
fi

echo "==> release preflight"
echo "    version: $VERSION ($BUILD_NUMBER)"
echo "    identity: $IDENTITY"
echo "    certificate SHA-256: $CERTIFICATE_SHA256"
echo "    notary profile: $NOTARY_PROFILE"
echo "    bundled SenseVoice: $BUNDLE_SENSEVOICE"
echo "    bundled HAL driver: $BUNDLE_HAL_DRIVER"
echo "    source revision: $SOURCE_REVISION"
echo "    source archive SHA-256: $SOURCE_ARCHIVE_SHA256"
echo "    source dirty: $SOURCE_DIRTY"
echo "    output: $RELEASE_DIR"

if ! xcrun notarytool history \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json >/dev/null; then
  cat >&2 <<EOF
error: notary profile '$NOTARY_PROFILE' is unavailable or invalid.
Create it once with:
  xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id YOUR_APPLE_ID --team-id "$TEAM_ID" --password YOUR_APP_SPECIFIC_PASSWORD
EOF
  exit 1
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

echo "==> building universal distribution app"
LINGSHU_VERSION="$VERSION" \
LINGSHU_BUILD_NUMBER="$BUILD_NUMBER" \
LINGSHU_SIGN_IDENTITY="$IDENTITY" \
LINGSHU_NOTARY_PROFILE="$NOTARY_PROFILE" \
LINGSHU_REQUIRE_DISTRIBUTION_SIGNING=1 \
LINGSHU_UNIVERSAL=1 \
LINGSHU_BUNDLE_SENSEVOICE="$BUNDLE_SENSEVOICE" \
LINGSHU_BUNDLE_HAL_DRIVER="$BUNDLE_HAL_DRIVER" \
LINGSHU_SOURCE_REVISION="$SOURCE_REVISION" \
  bash "$ROOT_DIR/Scripts/build-app.sh" release

[ -d "$APP_PATH" ] || fail "app bundle was not produced: $APP_PATH"

APP_BINARY="$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
CLI_BINARY="$APP_PATH/Contents/MacOS/lingshu"
BUNDLED_SOURCE_REVISION="$(plutil -extract LingShuSourceRevision raw -o - "$APP_PATH/Contents/Info.plist")"
[ "$BUNDLED_SOURCE_REVISION" = "$SOURCE_REVISION" ] \
  || fail "bundled source revision mismatch: expected $SOURCE_REVISION, got $BUNDLED_SOURCE_REVISION"
ARCHS="$(lipo -archs "$APP_BINARY")"
[[ " $ARCHS " == *" arm64 "* ]] || fail "app binary is missing arm64: $ARCHS"
[[ " $ARCHS " == *" x86_64 "* ]] || fail "app binary is missing x86_64: $ARCHS"
[ -x "$CLI_BINARY" ] || fail "bundled CLI was not produced: $CLI_BINARY"
CLI_ARCHS="$(lipo -archs "$CLI_BINARY")"
[[ " $CLI_ARCHS " == *" arm64 "* ]] || fail "CLI binary is missing arm64: $CLI_ARCHS"
[[ " $CLI_ARCHS " == *" x86_64 "* ]] || fail "CLI binary is missing x86_64: $CLI_ARCHS"
codesign --verify --strict --verbose=2 "$CLI_BINARY"
APP_BINARY_SHA256="$(shasum -a 256 "$APP_BINARY" | awk '{print $1}')"
CLI_BINARY_SHA256="$(shasum -a 256 "$CLI_BINARY" | awk '{print $1}')"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --verbose=4 "$APP_PATH" 2>&1 | grep -F "TeamIdentifier=$TEAM_ID" >/dev/null \
  || fail "signed app does not report expected TeamIdentifier $TEAM_ID"

PRIVATE_CONFIG="$(find "$APP_PATH/Contents/Resources/RuntimeConfig" -type f \( \
  -name '*.token' -o \
  -name '*.secret' -o \
  -iname '*secrets*.plist' -o \
  -iname '*credentials*.json' \
\) -print -quit 2>/dev/null || true)"
[ -z "$PRIVATE_CONFIG" ] || fail "private runtime credential found in public app: $PRIVATE_CONFIG"

echo "==> notarizing app"
APP_ZIP="$TMP_DIR/LingShu-app.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json > "$APP_NOTARY_LOG"
cat "$APP_NOTARY_LOG"
APP_NOTARY_STATUS="$(plutil -extract status raw -o - "$APP_NOTARY_LOG")"
[ "$APP_NOTARY_STATUS" = "Accepted" ] || fail "app notarization returned: $APP_NOTARY_STATUS"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "==> creating signed DMG"
mkdir -p "$DMG_STAGE"
ditto "$APP_PATH" "$DMG_STAGE/$PRODUCT_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "$PRODUCT_NAME" \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "==> notarizing DMG"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json > "$DMG_NOTARY_LOG"
cat "$DMG_NOTARY_LOG"
DMG_NOTARY_STATUS="$(plutil -extract status raw -o - "$DMG_NOTARY_LOG")"
[ "$DMG_NOTARY_STATUS" = "Accepted" ] || fail "DMG notarization returned: $DMG_NOTARY_STATUS"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

echo "==> verifying installed payload from DMG"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_POINT" >/dev/null
MOUNTED=1
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/$PRODUCT_NAME.app"
spctl --assess --type execute --verbose=4 "$MOUNT_POINT/$PRODUCT_NAME.app"
test -x "$MOUNT_POINT/$PRODUCT_NAME.app/Contents/MacOS/lingshu" \
  || fail "installed payload is missing bundled CLI"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
DMG_SIZE_BYTES="$(stat -f '%z' "$DMG_PATH")"
printf '%s  %s\n' "$SHA256" "$DMG_NAME" > "$DMG_PATH.sha256"

APP_NOTARY_ID="$(plutil -extract id raw -o - "$APP_NOTARY_LOG")"
DMG_NOTARY_ID="$(plutil -extract id raw -o - "$DMG_NOTARY_LOG")"

MANIFEST_PLIST="$TMP_DIR/release-manifest.plist"
plutil -create xml1 "$MANIFEST_PLIST"
plutil -insert product -string "$PRODUCT_NAME" "$MANIFEST_PLIST"
plutil -insert version -string "$VERSION" "$MANIFEST_PLIST"
plutil -insert build -integer "$BUILD_NUMBER" "$MANIFEST_PLIST"
plutil -insert bundle_id -string "com.zhaoroy.LingShu" "$MANIFEST_PLIST"
plutil -insert architectures -json '["arm64","x86_64"]' "$MANIFEST_PLIST"
plutil -insert team_id -string "$TEAM_ID" "$MANIFEST_PLIST"
plutil -insert signing_identity -string "$IDENTITY" "$MANIFEST_PLIST"
plutil -insert signing_certificate_sha256 -string "$CERTIFICATE_SHA256" "$MANIFEST_PLIST"
plutil -insert source_revision -string "$SOURCE_REVISION" "$MANIFEST_PLIST"
plutil -insert source_archive_sha256 -string "$SOURCE_ARCHIVE_SHA256" "$MANIFEST_PLIST"
plutil -insert app_binary_sha256 -string "$APP_BINARY_SHA256" "$MANIFEST_PLIST"
plutil -insert cli_binary_sha256 -string "$CLI_BINARY_SHA256" "$MANIFEST_PLIST"
plutil -insert source_dirty -bool "$SOURCE_DIRTY" "$MANIFEST_PLIST"
plutil -insert dmg_file -string "$DMG_NAME" "$MANIFEST_PLIST"
plutil -insert dmg_sha256 -string "$SHA256" "$MANIFEST_PLIST"
plutil -insert dmg_size_bytes -integer "$DMG_SIZE_BYTES" "$MANIFEST_PLIST"
plutil -insert bundled_sensevoice -bool "$BUNDLED_SENSEVOICE_BOOL" "$MANIFEST_PLIST"
plutil -insert bundled_hal_driver -bool "$BUNDLED_HAL_DRIVER_BOOL" "$MANIFEST_PLIST"
plutil -insert app_notarization_id -string "$APP_NOTARY_ID" "$MANIFEST_PLIST"
plutil -insert dmg_notarization_id -string "$DMG_NOTARY_ID" "$MANIFEST_PLIST"
plutil -insert created_at_utc -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MANIFEST_PLIST"
plutil -convert json -o "$MANIFEST_PATH" "$MANIFEST_PLIST"

echo
echo "Website release is ready:"
echo "  $DMG_PATH"
echo "  $DMG_PATH.sha256"
echo "  $MANIFEST_PATH"
