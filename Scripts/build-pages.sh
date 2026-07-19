#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/.site-output}"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/architecture" "$OUTPUT/assets/project-aurora" "$OUTPUT/examples/project-aurora"

cp "$ROOT/site/index.html" "$OUTPUT/index.html"
cp "$ROOT/site/architecture/index.html" "$OUTPUT/architecture/index.html"
cp "$ROOT/site/styles.css" "$OUTPUT/styles.css"
cp "$ROOT/site/app.js" "$OUTPUT/app.js"
cp "$ROOT/site/robots.txt" "$OUTPUT/robots.txt"
cp "$ROOT/site/sitemap.xml" "$OUTPUT/sitemap.xml"
cp "$ROOT/site/llms.txt" "$OUTPUT/llms.txt"
cp "$ROOT/Docs/media/lingshu-overview.jpg" "$OUTPUT/assets/lingshu-overview.jpg"
cp "$ROOT/Docs/media/lingshu-social-preview.png" "$OUTPUT/assets/lingshu-social-preview.png"
cp "$ROOT/Docs/media/lingshu-end-to-end-demo.mp4" "$OUTPUT/assets/lingshu-end-to-end-demo.mp4"
cp "$ROOT/Docs/media/lingshu-end-to-end-demo-poster.jpg" "$OUTPUT/assets/lingshu-end-to-end-demo-poster.jpg"
cp "$ROOT/Docs/media/project-aurora/slide-1.png" "$OUTPUT/assets/project-aurora/slide-1.png"
cp "$ROOT/Docs/media/project-aurora/slide-2.png" "$OUTPUT/assets/project-aurora/slide-2.png"
cp "$ROOT/Docs/media/project-aurora/slide-3.png" "$OUTPUT/assets/project-aurora/slide-3.png"
cp "$ROOT/Docs/media/project-aurora/slide-4.png" "$OUTPUT/assets/project-aurora/slide-4.png"
cp "$ROOT/Examples/project-aurora/project-aurora-demo.pdf" "$OUTPUT/examples/project-aurora/project-aurora-demo.pdf"
cp "$ROOT/Examples/project-aurora/project-aurora-demo.pptx" "$OUTPUT/examples/project-aurora/project-aurora-demo.pptx"
cp "$ROOT/Examples/project-aurora/project-aurora-demo.docx" "$OUTPUT/examples/project-aurora/project-aurora-demo.docx"
cp "$ROOT/lingshu-icon-preview.png" "$OUTPUT/assets/lingshu-icon-preview.png"
touch "$OUTPUT/.nojekyll"

printf 'Built LingShu Pages site at %s\n' "$OUTPUT"
