# LingShu v0.1.0-alpha Launch Kit

This document is the working launch pack for LingShu's first public alpha. It keeps every public claim tied to behavior that can be demonstrated from the release candidate.

## Core Positioning

English:

> LingShu is an Apache-2.0, model-agnostic macOS execution agent in the Codex / Claude Code category. Bring your own model and deliver verified code, documents, slides, and authorized computer actions through one open runtime.

中文：

> 灵枢是一套与 Codex / Claude Code 同类的 macOS 执行型 Agent：完整 App 与运行时采用 Apache-2.0 开源，主脑可替换，代码、文档、PPT 与授权后的电脑操作共用同一能力层。

Flagship proof:

> One brief becomes a complete, editable presentation or document report: the real file is created locally, registered, previewed, revised, and independently checked.

> 一条需求可以被推进为完整、可编辑的 PPT 或文档汇报：真实文件在本地生成、登记、预览、修改并经过独立验收。

The launch should repeatedly prove six things:

1. It belongs to the execution-agent category established by Codex and Claude Code, not the chat-app category.
2. The complete native app and agent runtime—not only a CLI—is published under Apache-2.0.
3. The model layer is replaceable: OpenAI, Anthropic, DeepSeek, MiniMax M3, and compatible custom endpoints share the same agent runtime.
4. Code is one deliverable, not the boundary: a brief can become software, an editable presentation or document, registered artifacts, and authorized Mac actions.
5. It delivers real files: artifacts are written to disk, registered, previewable, and revisitable.
6. It separates execution from verification: isolated workers can hand results to a checker before completion.

Comparison discipline:

- Codex CLI is Apache-2.0 open source; never describe all of Codex as closed source.
- Claude Code's official repository is public but its license is all rights reserved; describe that fact without implying the code is unavailable to inspect.
- Compare public product positioning and architecture, not unmeasured quality or model intelligence.
- Use "model-agnostic" to describe the gateway architecture, not to promise identical results from every model.

Do not claim that LingShu is the only agent capable of creating presentations or documents: current products can also create or edit office files. Prove the narrower and defensible difference instead—LingShu treats a report as a local, traceable, artifact-registered, independently checked workflow across replaceable model providers.

Do not claim that LingShu is production-ready, fully autonomous, fully local, or guaranteed safe. It is an alpha that can operate authorized local resources and can send selected context to the model provider configured by the user.

## Public Assets

- Repository screenshot: [`media/lingshu-overview.jpg`](./media/lingshu-overview.jpg)
- GitHub social preview: [`media/lingshu-social-preview.png`](./media/lingshu-social-preview.png)
- Reproducible Project Aurora sample: [`../Examples/project-aurora/README.md`](../Examples/project-aurora/README.md)
- Editable sample deck: [`../Examples/project-aurora/project-aurora-demo.pptx`](../Examples/project-aurora/project-aurora-demo.pptx)
- One-page sample brief: [`../Examples/project-aurora/project-aurora-demo.docx`](../Examples/project-aurora/project-aurora-demo.docx)
- Current release notes: [`releases/v0.1.0-alpha.6.md`](./releases/v0.1.0-alpha.6.md)
- First public alpha notes: [`releases/v0.1.0-alpha.md`](./releases/v0.1.0-alpha.md)
- Public operations checklist: [`OPEN_SOURCE_OPERATIONS.md`](./OPEN_SOURCE_OPERATIONS.md)

Upload `lingshu-social-preview.png` as the repository social preview when GitHub settings access is available. The source image is launch-ready, but do not claim the repository-level preview is configured until the upload is verified. Replace the current overview screenshot only after capturing an equally private, real run with a connected brain channel.

## 75-Second Demo

Record one continuous, reproducible workflow. Use a fresh macOS user or isolated demo data, hide notifications, and never show an API token, personal path, account name, browser history, or private document.

| Time | Screen action | Narration / subtitle | Proof shown |
| --- | --- | --- | --- |
| 0-7s | Show the installed LingShu app, its selected model, and a request for a project-report deck plus a one-page written summary. | "Codex and Claude Code proved the execution-agent model for software. LingShu opens the full native runtime, lets you choose the model, and takes the same idea beyond code." | Category, open runtime, replaceable model, concrete brief |
| 7-17s | Show the structured goal and plan appearing. | "The request becomes an explicit goal with acceptance criteria." | GoalSpec and plan |
| 17-34s | Open the task record while an isolated worker uses tools. | "Execution runs in a traceable task session instead of disappearing behind a spinner." | Live task state and tool trace |
| 34-48s | Show the PPTX and document being created and registered in the artifact list. | "The outputs are real editable files on disk, not filenames claimed in chat." | PPTX/document artifact registration |
| 48-61s | Show independent verification and its result. | "A checker evaluates the result before the task is closed." | Verification state |
| 61-70s | Preview the generated file from LingShu. | "The deliverable remains previewable and available to later tasks." | Built-in preview |
| 70-75s | End on the repository URL and release name. | "Native macOS. Bring your own model. Apache-2.0." | Clear next action |

Capture requirements:

- 1920x1080 or 2560x1440 source, exported at 1080p.
- Pointer and text must remain readable at normal playback speed.
- Use real elapsed states; speed up waiting sections visibly instead of cutting to fabricated success.
- Add English subtitles and a Chinese-subtitled version from the same recording.
- Keep the final cut between 60 and 90 seconds.

## English Launch Copy

### Hacker News

Title:

> Show HN: LingShu – an open-source, model-agnostic macOS agent beyond coding

Body:

> Codex and Claude Code showed how useful an execution-oriented agent can be for software engineering. I built LingShu to explore two different boundaries: can the complete native agent app remain open source, and can the agent layer work across model providers and deliverables beyond code?
>
> LingShu is an Apache-2.0 Swift app and agent runtime for macOS. You bring the model—OpenAI, Anthropic, DeepSeek, MiniMax, or a compatible endpoint—and keep the orchestration, task records, artifacts, memory, and permission-aware Computer Use layer on the Mac.
>
> Code is one deliverable, not the boundary. The same execution loop can produce software, an editable PPTX or DOCX, a PDF, or an authorized Mac workflow. Real files are registered in an artifact ledger, previewed from the task, and can be handed to an independent checker before completion.
>
> This is an alpha, not a claim of hands-off autonomy. It can operate files and authorized apps, so the release documents its permission and provider boundaries and asks users to review high-impact actions.
>
> The repository includes the app, more than 1,500 tests, architecture notes, a signed and notarized Universal DMG, a bundled CLI for external connectors, and a set of scoped starter issues. I would especially value reproducible feedback on first-run setup, model compatibility, macOS permissions, and task verification.
>
> Repository: https://github.com/RoyZhao1991/LingShu

### Short Social Post

> I open-sourced LingShu: an Apache-2.0, model-agnostic macOS execution agent in the Codex / Claude Code category. Bring OpenAI, Claude, DeepSeek, MiniMax, or a compatible model; deliver verified code, PPTX, DOCX, PDF, and authorized Mac actions through one open runtime. https://github.com/RoyZhao1991/LingShu

## 中文首发文案

### 社区长帖

标题：

> 我开源了灵枢：一款不锁模型、也不只交付代码的 macOS 执行型 Agent

正文：

> Codex 与 Claude Code 证明了执行型 Agent 在软件工程中的价值。我做灵枢，是想继续验证两个问题：完整的原生 Agent App 与运行时能不能真正开源；Agent 能不能不锁定某一家模型，也不把交付范围限制在代码里。
>
> 灵枢是一套 Apache-2.0 的 Swift 原生 macOS App 与 Agent 运行时。主脑由用户选择，支持 OpenAI、Anthropic Claude、DeepSeek、MiniMax 和兼容端点；任务编排、执行记录、产物账本、记忆和权限受控的 Computer Use 都留在 Mac 上。
>
> 代码只是交付物之一。相同的执行闭环还可以生成可编辑的 PPTX、DOCX、PDF，推进授权后的 Mac 工作流，并把真实文件登记、预览和交给独立 checker 验收。
>
> 这仍是 Alpha，不是“完全无人值守”的宣传。灵枢能够操作文件和已授权应用，因此仓库明确写出了权限、远程模型和高影响操作边界，并要求用户检查关键动作与交付结果。
>
> 首个版本提供源码、架构文档、超过 1,500 项测试、签名公证的 Universal DMG、用于外部连接器的内置 CLI，以及一批可以直接参与的 Issue。我最希望收到的是可复现反馈：首次配置是否顺畅、不同模型是否兼容、macOS 权限是否清晰、验收机制是否真的减少了“嘴上完成”。
>
> 项目地址：https://github.com/RoyZhao1991/LingShu

### 中文短帖

> 灵枢开源了：一套与 Codex / Claude Code 同类的 macOS 执行型 Agent。完整 App 与运行时采用 Apache-2.0，主脑可替换；代码、PPTX、DOCX、PDF 和授权后的 Mac 操作共用同一能力层。https://github.com/RoyZhao1991/LingShu

## Launch Sequence

1. Publish `v0.1.0-alpha` with the signed, notarized Universal DMG and SHA-256 file.
2. Confirm the public repository, release links, CI badge, issue templates, Discussions, and vulnerability reporting from a signed-out browser.
3. Upload the repository social preview and pin the release announcement discussion.
4. Publish the demo and English launch post; publish the Chinese version after the download path has been independently checked.
5. For the first 48 hours, prioritize install, launch, permission, token setup, and crash reports over new feature requests.
6. Record traffic, unique cloners, release downloads, stars, issue response time, and confirmed successful installs once per day for seven days.

Never buy stars, exchange stars, mass-message strangers, or use unreproducible demos. A smaller group of successful installers and contributors is more valuable than a short-lived vanity spike.
