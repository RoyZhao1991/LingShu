# LingShu v0.1.0-alpha Launch Kit

This document is the working launch pack for LingShu's first public alpha. It keeps every public claim tied to behavior that can be demonstrated from the release candidate.

## Core Positioning

English:

> LingShu is a native macOS AI agent that turns goals into verified deliverables, with a replaceable model brain and local orchestration.

中文：

> 灵枢是一款原生 macOS AI Agent：主脑可替换，编排与执行留在本机，并把用户目标推进为经过验收的真实产物。

The launch should repeatedly prove four things:

1. It acts beyond chat: a request becomes a structured goal, execution plan, tool work, and a completion decision.
2. It delivers real files: artifacts are written to disk, registered, previewable, and revisitable.
3. It separates execution from verification: isolated workers can hand results to a checker before completion.
4. It is not tied to one model vendor: OpenAI, Anthropic, DeepSeek, MiniMax M3, and compatible custom endpoints share the same agent layer.

Do not claim that LingShu is production-ready, fully autonomous, fully local, or guaranteed safe. It is an alpha that can operate authorized local resources and can send selected context to the model provider configured by the user.

## Public Assets

- Repository screenshot: [`media/lingshu-overview.jpg`](./media/lingshu-overview.jpg)
- GitHub social preview: [`media/lingshu-social-preview.png`](./media/lingshu-social-preview.png)
- Release notes: [`releases/v0.1.0-alpha.md`](./releases/v0.1.0-alpha.md)
- Public operations checklist: [`OPEN_SOURCE_OPERATIONS.md`](./OPEN_SOURCE_OPERATIONS.md)

Before opening the repository, upload `lingshu-social-preview.png` as the repository social preview. Replace the current overview screenshot only after capturing an equally private, real run with a connected brain channel.

## 75-Second Demo

Record one continuous, reproducible workflow. Use a fresh macOS user or isolated demo data, hide notifications, and never show an API token, personal path, account name, browser history, or private document.

| Time | Screen action | Narration / subtitle | Proof shown |
| --- | --- | --- | --- |
| 0-7s | Show the installed LingShu app and enter one concrete request that produces a small document or code artifact. | "Most AI desktop apps stop at an answer. LingShu continues to a deliverable." | Native app, real input |
| 7-17s | Show the structured goal and plan appearing. | "The request becomes an explicit goal with acceptance criteria." | GoalSpec and plan |
| 17-34s | Open the task record while an isolated worker uses tools. | "Execution runs in a traceable task session instead of disappearing behind a spinner." | Live task state and tool trace |
| 34-48s | Show a file being created and registered in the artifact list. | "The output is a real file on disk, not a claim in chat." | Artifact registration |
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

> Show HN: LingShu – a native macOS AI agent that turns goals into verified deliverables

Body:

> I built LingShu because I wanted a desktop agent that did more than produce a plausible answer. A request becomes a structured goal, runs through local tools or isolated workers, produces real files, and can be checked before completion.
>
> LingShu is written in Swift for macOS. The orchestration, task records, artifacts, memory, and permission-aware Computer Use runtime live on the Mac. You bring the model: the first alpha supports OpenAI, Anthropic, DeepSeek, MiniMax M3, and compatible custom endpoints.
>
> This is an alpha, not a claim of hands-off autonomy. It can operate files and authorized apps, so the release documents its permission and provider boundaries and asks users to review high-impact actions.
>
> The repository includes the app, 1,526 tests, architecture notes, a signed and notarized Universal DMG, and a set of scoped starter issues. I would especially value reproducible feedback on first-run setup, model compatibility, macOS permissions, and task verification.
>
> Repository: https://github.com/RoyZhao1991/LingShu

### Short Social Post

> I open-sourced LingShu, a native macOS AI agent that turns goals into verified deliverables. It can plan, dispatch isolated workers, use local tools and authorized Mac apps, register real artifacts, and verify results before completion. Bring your own OpenAI, Anthropic, DeepSeek, MiniMax, or compatible model. Apache-2.0. https://github.com/RoyZhao1991/LingShu

## 中文首发文案

### 社区长帖

标题：

> 我开源了灵枢：一款把目标推进为可验收产物的原生 macOS AI Agent

正文：

> 我做灵枢，是因为现有桌面 AI 经常停在“给出一个看起来合理的回答”。我希望一次请求能够继续变成明确目标、执行计划、工具调用、真实文件和可检查的完成结论。
>
> 灵枢使用 Swift 原生开发。任务编排、执行记录、产物登记、记忆和基于 macOS 权限的 Computer Use 都运行在本机；主脑可以自行选择，目前支持 OpenAI、Anthropic Claude、DeepSeek、MiniMax M3 和自定义兼容端点。
>
> 这仍是 Alpha，不是“完全无人值守”的宣传。灵枢能够操作文件和已授权应用，因此仓库明确写出了权限、远程模型和高影响操作边界，并要求用户检查关键动作与交付结果。
>
> 首个版本提供源码、架构文档、1,526 项测试、签名公证的 Universal DMG，以及一批可以直接参与的 Issue。我最希望收到的是可复现反馈：首次配置是否顺畅、不同模型是否兼容、macOS 权限是否清晰、验收机制是否真的减少了“嘴上完成”。
>
> 项目地址：https://github.com/RoyZhao1991/LingShu

### 中文短帖

> 灵枢开源了：原生 macOS AI Agent，主脑可替换，编排与执行留在本机，把请求推进为经过验收的真实文件和任务结果。支持 OpenAI、Claude、DeepSeek、MiniMax 与兼容端点，Apache-2.0。https://github.com/RoyZhao1991/LingShu

## Launch Sequence

1. Publish `v0.1.0-alpha` with the signed, notarized Universal DMG and SHA-256 file.
2. Confirm the public repository, release links, CI badge, issue templates, Discussions, and vulnerability reporting from a signed-out browser.
3. Upload the repository social preview and pin the release announcement discussion.
4. Publish the demo and English launch post; publish the Chinese version after the download path has been independently checked.
5. For the first 48 hours, prioritize install, launch, permission, token setup, and crash reports over new feature requests.
6. Record traffic, unique cloners, release downloads, stars, issue response time, and confirmed successful installs once per day for seven days.

Never buy stars, exchange stars, mass-message strangers, or use unreproducible demos. A smaller group of successful installers and contributors is more valuable than a short-lived vanity spike.
