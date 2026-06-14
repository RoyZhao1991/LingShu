#!/usr/bin/env bash
# 预备 DesignKB 图标:从 Lucide(ISC 许可)拉一份精选子集 SVG,栅格化成 白/深 两版透明 PNG,
# 落到 Resources/DesignKB/icons/lucide/。可重跑扩集。产物 PNG 提交进仓库,运行期零 SVG 依赖。
# 栅格化器:优先 rsvg-convert(brew install librsvg,保留透明),回退 cairosvg。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT_DIR/Resources/DesignKB/icons/lucide"
RAW="https://raw.githubusercontent.com/lucide-icons/lucide/main/icons"
SIZE="${SIZE:-160}"
WHITE="#FFFFFF"; DARK="#1A1F2B"

# 选栅格化器
if command -v rsvg-convert >/dev/null 2>&1; then
  RASTER="rsvg"
elif [ -x "$HOME/.local/bin/cairosvg" ] && "$HOME/.local/bin/cairosvg" --help >/dev/null 2>&1; then
  RASTER="cairo"; CAIROSVG="$HOME/.local/bin/cairosvg"
elif command -v cairosvg >/dev/null 2>&1 && cairosvg --help >/dev/null 2>&1; then
  RASTER="cairo"; CAIROSVG="cairosvg"
else
  echo "需要 rsvg-convert(brew install librsvg)或可用的 cairosvg"; exit 1
fi
echo "栅格化器: $RASTER"

render() {  # render <svg-file> <png-out>
  if [ "$RASTER" = "rsvg" ]; then
    rsvg-convert -w "$SIZE" -h "$SIZE" "$1" -o "$2" 2>/dev/null
  else
    "$CAIROSVG" "$1" -o "$2" --output-width "$SIZE" --output-height "$SIZE" 2>/dev/null
  fi
}

mkdir -p "$OUT"

# PPT 常用图标精选(Lucide 名)。可按需追加。
ICONS=(
  zap target users user rocket settings shield trending-up trending-down check
  check-circle circle-check x lightbulb brain cpu database cloud lock key eye
  mic message-square bell calendar clock map-pin globe search filter layers
  layout-grid bar-chart-3 line-chart pie-chart activity award star heart
  thumbs-up flag compass route git-branch workflow wrench hammer code terminal
  folder file-text image camera video play arrow-right arrow-up-right
  chevron-right plus minus refresh-cw repeat link share-2 send download upload
  mail phone building briefcase dollar-sign shopping-cart package truck leaf
  sun moon sparkles gauge smartphone monitor server wifi bot handshake
  book-open graduation-cap crown gem flame
)

ok=0; skip=0
for name in "${ICONS[@]}"; do
  svg="$(curl -fsSL "$RAW/$name.svg" 2>/dev/null || true)"
  case "$svg" in
    *"<svg"*) : ;;
    *) echo "  skip(404): $name"; skip=$((skip+1)); continue ;;
  esac
  tmp="$(mktemp).svg"
  echo "${svg//currentColor/$WHITE}" > "$tmp"
  render "$tmp" "$OUT/$name-white.png" || { echo "  fail: $name"; rm -f "$tmp"; continue; }
  echo "${svg//currentColor/$DARK}" > "$tmp"
  render "$tmp" "$OUT/$name-dark.png" || true
  rm -f "$tmp"
  ok=$((ok+1))
done

cat > "$OUT/LICENSE" <<'LIC'
Icons from Lucide (https://github.com/lucide-icons/lucide) — ISC License.
Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT).
All other copyright (c) for Lucide are held by Lucide Contributors 2022.
Bundled here as pre-rasterized PNG (white/dark) for offline use in 灵枢 DesignKB.
LIC

echo "done: $ok icons (×2 PNG), skipped $skip → $OUT"
