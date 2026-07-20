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

require_copy() {
  local expected="$1"
  if ! grep -Fq "$expected" "$OUTPUT/index.html"; then
    printf 'Missing required first-run copy: %s\n' "$expected" >&2
    exit 1
  fi
}

require_copy "Your first 15 minutes"
require_copy "LingShu is free and BYOK; inference credits are not included."
require_copy "A real <code>.docx</code> appears in Workspace"
require_copy "Report success, partial, or failure"
require_copy "首个 15 分钟"
require_copy "灵枢免费开源，但需要自备模型 Token，不包含推理额度。"
require_copy "Workspace 中出现真实 <code>.docx</code> 文件"
require_copy "提交成功、部分成功或失败结果"

if grep -Fq "Three-minute path" "$OUTPUT/index.html"; then
  printf 'Outdated first-run timing claim remains in the published page.\n' >&2
  exit 1
fi

printf 'Built LingShu Pages site at %s\n' "$OUTPUT"
