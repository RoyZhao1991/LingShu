#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/.site-output}"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/assets"

cp "$ROOT/site/index.html" "$OUTPUT/index.html"
cp "$ROOT/site/styles.css" "$OUTPUT/styles.css"
cp "$ROOT/site/app.js" "$OUTPUT/app.js"
cp "$ROOT/site/robots.txt" "$OUTPUT/robots.txt"
cp "$ROOT/site/sitemap.xml" "$OUTPUT/sitemap.xml"
cp "$ROOT/Docs/media/lingshu-overview.jpg" "$OUTPUT/assets/lingshu-overview.jpg"
cp "$ROOT/Docs/media/lingshu-social-preview.png" "$OUTPUT/assets/lingshu-social-preview.png"
cp "$ROOT/lingshu-icon-preview.png" "$OUTPUT/assets/lingshu-icon-preview.png"
touch "$OUTPUT/.nojekyll"

printf 'Built LingShu Pages site at %s\n' "$OUTPUT"
