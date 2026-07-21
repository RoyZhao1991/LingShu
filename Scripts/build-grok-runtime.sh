#!/usr/bin/env bash
# Build the Grok-derived engine as an in-process LingShu runtime library.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GROK_DIR="$ROOT_DIR/Runtime/Grok"
CONFIG="${1:-debug}"
DESTINATION="${2:-}"
UNIVERSAL_BUILD="${LINGSHU_UNIVERSAL:-0}"
CARGO_BIN="${LINGSHU_CARGO_BIN:-$(command -v cargo || true)}"

[ -n "$CARGO_BIN" ] && [ -x "$CARGO_BIN" ] || {
  echo "error: Cargo is required to build the embedded Loop Runtime" >&2
  exit 1
}

if [ "$CONFIG" = "release" ] || [ "$CONFIG" = "Release" ]; then
  CARGO_FLAG="--release"
  PROFILE="release"
else
  CARGO_FLAG=""
  PROFILE="debug"
fi

if [ "$UNIVERSAL_BUILD" = "1" ]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lingshu-grok-runtime.XXXXXX")"
  trap 'rm -rf "$WORK_DIR"' EXIT
  LIBRARIES=()
  for TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    echo "==> cargo build lingshu-grok-runtime ($PROFILE, $TARGET)"
    (cd "$GROK_DIR" && "$CARGO_BIN" build -p lingshu-grok-runtime $CARGO_FLAG --target "$TARGET")
    LIBRARIES+=("$GROK_DIR/target/$TARGET/$PROFILE/liblingshu_grok_runtime.dylib")
  done
  BUILT_LIBRARY="$WORK_DIR/liblingshu_grok_runtime.dylib"
  lipo -create "${LIBRARIES[@]}" -output "$BUILT_LIBRARY"
else
  echo "==> cargo build lingshu-grok-runtime ($PROFILE)"
  (cd "$GROK_DIR" && "$CARGO_BIN" build -p lingshu-grok-runtime $CARGO_FLAG)
  BUILT_LIBRARY="$GROK_DIR/target/$PROFILE/liblingshu_grok_runtime.dylib"
fi

if [ -n "$DESTINATION" ]; then
  mkdir -p "$DESTINATION"
  cp "$BUILT_LIBRARY" "$DESTINATION/liblingshu_grok_runtime.dylib"
  if command -v install_name_tool >/dev/null 2>&1; then
    install_name_tool -id "@rpath/liblingshu_grok_runtime.dylib" \
      "$DESTINATION/liblingshu_grok_runtime.dylib"
  fi
  echo "$DESTINATION/liblingshu_grok_runtime.dylib"
else
  echo "$BUILT_LIBRARY"
fi
