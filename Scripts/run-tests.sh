#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BIN_PATH="$(swift build --package-path "$PACKAGE_ROOT" --show-bin-path)"
swift build --package-path "$PACKAGE_ROOT" --build-tests

TEST_BUNDLE="$BIN_PATH/LingShuMacPackageTests.xctest"

if [[ ! -d "$TEST_BUNDLE" ]]; then
  echo "Test bundle not found: $TEST_BUNDLE" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lingshu-tests.XXXXXX")"
trap 'rm -rf "$RUN_DIR"' EXIT

RUN_BUNDLE="$RUN_DIR/LingShuMacPackageTests.xctest"
cp -R "$TEST_BUNDLE" "$RUN_BUNDLE"
xattr -cr "$RUN_BUNDLE"
codesign --force --deep --sign - "$RUN_BUNDLE" >/dev/null
codesign --verify --deep --strict "$RUN_BUNDLE" >/dev/null

if [[ $# -gt 0 ]]; then
  xcrun xctest -XCTest "$*" "$RUN_BUNDLE"
else
  xcrun xctest "$RUN_BUNDLE"
fi
