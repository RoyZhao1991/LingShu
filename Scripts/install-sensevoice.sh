#!/usr/bin/env bash
# 下载并安装 SenseVoice / sherpa-onnx 本地 ASR 运行时 + 模型到 Models/SenseVoice。
# 目的:让麦克风走 SenseVoice(独立引擎)、系统声音走 Apple SFSpeech,两路 ASR 不再撞车(并发)。
# build-app.sh 会把 Models/SenseVoice 打进 .app(随灵枢一起交付)。模型较大(~250MB),不入 git。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT_DIR/Models/SenseVoice"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SHERPA_VER="v1.13.3"
RUNTIME_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VER}/sherpa-onnx-${SHERPA_VER}-osx-arm64-shared-no-tts.tar.bz2"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
VAD_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"

BIN_NAME="sherpa-onnx-vad-microphone-offline-asr"

# 已装齐就跳过(幂等:build-app.sh 每次构建都会调,装过不重复下)。
if [ -x "$DEST/bin/$BIN_NAME" ] && [ -f "$DEST/model.int8.onnx" ] && [ -f "$DEST/tokens.txt" ] && [ -f "$DEST/silero_vad.onnx" ]; then
  echo "==> SenseVoice 已安装,跳过 ($DEST)"
  exit 0
fi

echo "==> 下载 SenseVoice 运行时 + 模型(~250MB,首次较慢)…"
mkdir -p "$DEST/bin" "$DEST/lib"

echo "   - 运行时 sherpa-onnx ${SHERPA_VER}"
curl -fL --retry 3 -o "$TMP/runtime.tar.bz2" "$RUNTIME_URL"
echo "   - SenseVoice int8 模型"
curl -fL --retry 3 -o "$TMP/model.tar.bz2" "$MODEL_URL"
echo "   - silero VAD"
curl -fL --retry 3 -o "$DEST/silero_vad.onnx" "$VAD_URL"

echo "==> 解包 + 归位"
tar -xjf "$TMP/runtime.tar.bz2" -C "$TMP"
RT_DIR="$(find "$TMP" -maxdepth 1 -type d -name 'sherpa-onnx-*' | head -1)"
[ -n "$RT_DIR" ] || { echo "运行时解包失败"; exit 1; }
# 取 vad-microphone-offline-asr 二进制 + 所有 dylib(locator: bin/<binary>,lib/*.dylib)。
cp "$RT_DIR/bin/$BIN_NAME" "$DEST/bin/$BIN_NAME"
find "$RT_DIR/lib" -name '*.dylib' -exec cp {} "$DEST/lib/" \;

tar -xjf "$TMP/model.tar.bz2" -C "$TMP"
MODEL_DIR="$(find "$TMP" -maxdepth 1 -type d -name 'sherpa-onnx-sense-voice-*' | head -1)"
[ -n "$MODEL_DIR" ] || { echo "模型解包失败"; exit 1; }
# locator 在 root 找 model.int8.onnx / tokens.txt。
cp "$MODEL_DIR/model.int8.onnx" "$DEST/model.int8.onnx"
cp "$MODEL_DIR/tokens.txt" "$DEST/tokens.txt"

# 去隔离 + ad-hoc 签名(下载来的二进制/动态库默认带 quarantine,Gatekeeper 会拦;build-app.sh 会用正式身份重签)。
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
chmod +x "$DEST/bin/$BIN_NAME"
codesign --force --sign - "$DEST/lib/"*.dylib 2>/dev/null || true
codesign --force --sign - "$DEST/bin/$BIN_NAME" 2>/dev/null || true

echo "==> SenseVoice 安装完成:"
echo "    binary: $DEST/bin/$BIN_NAME"
echo "    model:  $DEST/model.int8.onnx"
echo "    tokens: $DEST/tokens.txt"
echo "    vad:    $DEST/silero_vad.onnx"
echo "    dylibs: $(ls "$DEST/lib" | wc -l | tr -d ' ') 个"
