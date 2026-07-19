![LingShu: a native macOS agent for verified deliverables](https://royzhao1991.github.io/LingShu/assets/lingshu-social-preview.png)

LingShu is now available as a public alpha: a fully open-source, model-agnostic macOS execution agent in the Codex / Claude Code category.

The premise is simple: **your model, your agent runtime, and deliverables beyond code.**

## What makes LingShu different

- **Complete native runtime under Apache-2.0.** The SwiftUI app and agent layer are both open for inspection and contribution.
- **Bring your own model.** Use OpenAI, Claude, DeepSeek, MiniMax, or an OpenAI-compatible endpoint through the same provider-neutral layer.
- **Code is one deliverable, not the boundary.** LingShu can produce editable PPTX and DOCX files, PDFs, media, local apps, and authorized Mac workflows.
- **Delivery is verified.** Real files are registered in an artifact ledger, previewed locally, and can be checked by an independent agent before completion.
- **Human interaction is structured.** Login, QR scanning, file selection, confirmation, and sensitive actions pause the exact task and resume from the same point.

This is a category and architecture claim, not a benchmark claim. Codex CLI is also Apache-2.0; Claude Code's official repository currently uses Anthropic's commercial terms. LingShu's distinction is the open native app/runtime, replaceable model layer, and broader default delivery surface.

## Reproducible proof

The public Project Aurora sample contains a four-slide editable PowerPoint, a one-page Word document, PDF output, page previews, and the checker trail. It uses synthetic data only, so anyone can inspect the actual deliverables without trusting a screenshot.

- Website and sample: https://royzhao1991.github.io/LingShu/
- Source: https://github.com/RoyZhao1991/LingShu
- Signed and notarized alpha: https://github.com/RoyZhao1991/LingShu/releases/tag/v0.1.0-alpha.7
- Homebrew: `brew install --cask RoyZhao1991/tap/lingshu`

## What feedback would help most

1. Can you complete a clean install and first-run model setup?
2. Which model or compatible endpoint did you test?
3. Did the generated artifact open, remain editable, and match the requested structure?
4. Were permission and human-interaction boundaries clear?
5. Which part would you be interested in contributing to?

This is an alpha. Expect rough edges, and please avoid using irreplaceable files while testing. If the idea of an open, model-neutral macOS agent is useful to you, **star the repository, try the sample, and open a reproducible issue**. Those three signals tell us far more than a download count.

---

## 中文摘要

灵枢现已进入公开 Alpha：它与 Codex / Claude Code 属于同一类执行型 Agent，但把完整原生 App 与运行时以 Apache-2.0 开源，把主脑做成可替换能力，并把代码、PPT、文档、PDF、媒体和授权后的 Mac 操作统一纳入可验收交付流程。

我们最希望获得三类真实反馈：全新安装是否顺利、不同模型/兼容端点是否可用、产物是否真实可打开且符合要求。如果你认同“模型属于用户，Agent 运行时也应当开放”这一方向，欢迎 Star、试用公开样例并提交可复现问题。
