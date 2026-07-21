#!/usr/bin/env bash
# Build the Grok-derived engine as an in-process LingShu runtime library.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GROK_DIR="$ROOT_DIR/Runtime/Grok"
CONFIG="${1:-debug}"
DESTINATION="${2:-}"
UNIVERSAL_BUILD="${LINGSHU_UNIVERSAL:-0}"
CARGO_BIN="${LINGSHU_CARGO_BIN:-$(command -v cargo || true)}"
RG_VERSION="15.0.0"
RG_CACHE_DIR="${LINGSHU_RG_CACHE_DIR:-$GROK_DIR/target/lingshu-release-tools/ripgrep}"

[ -n "$CARGO_BIN" ] && [ -x "$CARGO_BIN" ] || {
  echo "error: Cargo is required to build the embedded Loop Runtime" >&2
  exit 1
}

prepare_bundled_rg() {
  local target="$1"
  local expected_sha
  case "$target" in
    aarch64-apple-darwin)
      expected_sha="98bb2e61e7277ba0ea72d2ae2592497fd8d2940934a16b122448d302a6637e3b"
      ;;
    x86_64-apple-darwin)
      expected_sha="44128c733d127ddbda461e01225a68b5f9997cfe7635242a797f645ca674a71a"
      ;;
    *)
      echo "error: no pinned ripgrep release asset for $target" >&2
      return 1
      ;;
  esac

  local asset="ripgrep-$RG_VERSION-$target.tar.gz"
  local cache_dir="$RG_CACHE_DIR/$target"
  local archive="$cache_dir/$asset"
  local binary="$cache_dir/rg"
  local url="https://github.com/BurntSushi/ripgrep/releases/download/$RG_VERSION/$asset"
  mkdir -p "$cache_dir"

  if [ ! -f "$archive" ] || [ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" != "$expected_sha" ]; then
    local download="$archive.download"
    rm -f "$download"
    echo "==> download pinned ripgrep $RG_VERSION ($target)" >&2
    /usr/bin/curl --fail --location --retry 3 --silent --show-error \
      --output "$download" "$url"
    local actual_sha
    actual_sha="$(/usr/bin/shasum -a 256 "$download" | /usr/bin/awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
      rm -f "$download"
      echo "error: ripgrep checksum mismatch for $target" >&2
      return 1
    fi
    mv "$download" "$archive"
    rm -f "$binary"
  fi

  if [ ! -x "$binary" ]; then
    local extract_dir
    extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/lingshu-rg.XXXXXX")"
    /usr/bin/tar -xzf "$archive" -C "$extract_dir"
    local extracted="$extract_dir/ripgrep-$RG_VERSION-$target/rg"
    if [ ! -f "$extracted" ]; then
      rm -rf "$extract_dir"
      echo "error: ripgrep archive does not contain the expected binary for $target" >&2
      return 1
    fi
    cp "$extracted" "$binary"
    chmod 755 "$binary"
    rm -rf "$extract_dir"
  fi

  echo "$binary"
}

build_runtime_target() {
  local target="$1"
  echo "==> cargo build lingshu-grok-runtime ($PROFILE, $target)"
  if [ "$PROFILE" = "release" ]; then
    local rg_binary
    rg_binary="$(prepare_bundled_rg "$target")"
    (cd "$GROK_DIR" && \
      GROK_TOOLS_BUNDLE_RG_PATH="$rg_binary" \
      GROK_SHELL_BUNDLE_RG_PATH="$rg_binary" \
      "$CARGO_BIN" build -p lingshu-grok-runtime $CARGO_FLAG --target "$target")
  else
    (cd "$GROK_DIR" && "$CARGO_BIN" build -p lingshu-grok-runtime $CARGO_FLAG --target "$target")
  fi
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
    build_runtime_target "$TARGET"
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
