# LingShu Community Launch Pack

This pack turns LingShu's verified product facts into community-native launch material. It is not a request for coordinated Stars. Every publication should invite testing, technical questions, or contributions and should be measured by repository visits, successful installs, reproducible feedback, and outside contributions.

## Verified Facts

- Category: native macOS execution agent in the Codex / Claude Code category, not a chat wrapper.
- License: complete native app and agent runtime are Apache-2.0.
- Model layer: users can bring OpenAI, Anthropic, DeepSeek, MiniMax, or a compatible endpoint.
- Deliverables: code, editable PPTX and DOCX, PDF, media, and authorized Mac actions share the same runtime.
- Evidence: task records, artifact registration, built-in preview, human checkpoints, and an independent checker.
- Current maturity: public Alpha for macOS 14 or later; users should review important actions and outputs.
- Install: signed and notarized Universal DMG or Homebrew Cask.
- Repository: https://github.com/RoyZhao1991/LingShu
- Real task replay and editable sample: https://royzhao1991.github.io/LingShu/#deliverables
- Release: https://github.com/RoyZhao1991/LingShu/releases/tag/v0.1.0-alpha.6

## Launch Queue

| Order | Channel | Audience-specific question | Publication gate | Measurement window |
| --- | --- | --- | --- | --- |
| 1 | Show HN | Should the agent runtime and model backend be separable, and should verified files be first-class deliverables? | Founder writes the final title and text in their own words; repository, release, and sample must be publicly usable | Seven full days |
| 2 | `r/LLMDevs` | Does one provider-neutral runtime behave predictably across different model APIs? | Free open-source project; disclose Alpha status and BYO model requirement; post once | Seven full days |
| 3 | V2EX `分享创造` | Can a domestic or overseas model drive the same open macOS execution runtime and produce real deliverables? | Use a personal build story, not company-style marketing; post in `分享创造` | Seven full days |
| 4 | `r/ChatGPTCoding` self-promotion thread | What should a coding-agent user expect when the same execution loop also owns documents, slides, and verification? | Use the designated self-promotion thread; post LingShu only once | Seven full days |
| 5 | Product Hunt | Is the signed Alpha install and first-run model setup clear enough for a broader product audience? | Wait for at least three independent install reports and a clean 60–90 second demo | Seven full days |

Do not publish these entries on the same day. A failed channel is still useful evidence; record it rather than reposting immediately.

## Show HN Founder Worksheet

Hacker News explicitly asks authors not to post generated or AI-edited text. Do not paste a generated launch body. The founder should write the final submission personally, using the factual prompts below, then publish only after checking the [Show HN rules](https://news.ycombinator.com/showhn.html) and [site guidelines](https://news.ycombinator.com/newsguidelines.html).

Write five short paragraphs in your own words:

1. What repeated problem made you start LingShu, and why did existing execution agents not cover that exact need?
2. Why did you make the complete Swift app and runtime Apache-2.0 instead of tying the product to one hosted model?
3. What can a visitor run today? Mention the signed Alpha, model setup, and one reproducible Project Aurora workflow.
4. What is technically different? Keep this concrete: GoalSpec, task session, tools, artifact ledger, human checkpoint, checker.
5. What is still weak? State the Alpha limitations and ask for specific feedback on first-run setup, provider compatibility, permissions, and verification.

Title ingredients, not a ready-to-paste title:

- Prefix: `Show HN:`
- Name: `LingShu`
- Category: open-source macOS execution agent
- Distinction: replaceable model backend or verified non-code deliverables

Before publication:

- Open the repository, website sample, release, and Homebrew command from a signed-out browser.
- Confirm the founder's HN account is eligible for Show HN under current site restrictions.
- Remove private paths, credentials, personal notifications, and fabricated claims.
- Stay available for two hours and answer technical questions directly.
- Do not request votes, comments, or coordinated traffic.

## Reddit: `r/LLMDevs`

The community's published self-promotion policy permits free open-source projects without prior moderator approval while prohibiting disguised advertising. Recheck the [current rule announcement](https://www.reddit.com/r/LLMDevs/comments/1mvuw5x/community_rule_update_clarifying_our/) immediately before posting.

Suggested title:

> I open-sourced the full macOS agent runtime so the model backend can be swapped

Draft to adapt before posting:

> I kept running into a boundary with execution agents: the model, orchestration, task history, permissions, and deliverable format often arrive as one product decision. I wanted to test a different architecture, so I built LingShu.
>
> LingShu is an Apache-2.0 native macOS app and agent runtime. The model is a replaceable dependency: OpenAI, Anthropic, DeepSeek, MiniMax, and compatible endpoints use the same task, tool, memory, permission, artifact, and verification layers.
>
> It is in the Codex / Claude Code category, but code is not the only first-class deliverable. A task can create editable PPTX or DOCX files, PDFs, media, or authorized Mac actions. Files are written locally, registered in an artifact ledger, previewed from the task, and can be checked by an independent role before completion.
>
> The current release is an Alpha for macOS 14+, not a claim of unattended autonomy. It requires your own model endpoint, and important actions and outputs still need review. The repository includes a signed Universal DMG, Homebrew install, architecture notes, tests, and a reproducible PPTX/DOCX example.
>
> I would value implementation-level feedback on three points: provider compatibility, whether the human checkpoint model is understandable, and whether artifact registration plus an independent checker reduces false completion in practice.
>
> Code: https://github.com/RoyZhao1991/LingShu
>
> 16-second task replay and editable sample: https://royzhao1991.github.io/LingShu/#deliverables

Publication notes:

- Disclose that you are the author.
- Do not add a "please Star" line.
- Reply with evidence, not a feature inventory.
- If asked about local operation, explain that orchestration and artifacts are local while selected context is sent to the user's configured model provider.

## V2EX: `分享创造`

V2EX describes `分享创造` as the place for independent developers to share new work and find early users. Recheck the [node guidance](https://www.v2ex.com/help/node) immediately before posting.

Suggested title:

> 分享一个我做的开源 macOS 执行 Agent：完整运行时开源、主脑可替换，交付不只代码

Draft to adapt before posting:

> 我做灵枢，不是想再做一个聊天壳，而是想验证一套更开放的执行型 Agent 架构。
>
> Codex 和 Claude Code 已经证明了“模型理解目标、调用工具、推进任务并交付结果”这条路径的价值。我的问题是：完整的原生 App 和运行时能不能一起开源；主脑能不能像依赖一样替换；同一套执行闭环能不能除了代码，也交付可编辑的 PPT、Word、PDF 和经过授权的 Mac 操作。
>
> 目前灵枢是一套 Apache-2.0 的 Swift 原生 macOS App 与 Agent 运行时。可以接 OpenAI、Claude、DeepSeek、MiniMax 或兼容端点。任务会形成明确目标和步骤，执行过程有记录，真实文件进入产物账本，可以直接预览，也可以在完成前交给独立 checker 验收；遇到扫码、登录、授权等人机交互时，会暂停并在 App 内等待用户处理后继续。
>
> 我把一个真实的 PPTX/DOCX 任务做成了 16 秒回放，同时放出了可编辑样例。当前版本仍是 Alpha，只支持 macOS 14 及以上，需要用户自备模型通道，重要操作和交付结果也应该人工确认。
>
> 我现在最需要的不是泛泛的功能建议，而是三类可复现反馈：首次安装和主脑配置是否顺畅；不同模型端点是否兼容；“产物登记 + 独立验收”是否真的减少了 Agent 嘴上说完成、文件却不可用的问题。
>
> GitHub：https://github.com/RoyZhao1991/LingShu
>
> 真实任务回放和可编辑样例：https://royzhao1991.github.io/LingShu/#deliverables

Publication notes:

- Choose `分享创造`, not a generic technical node or `推广`, unless the post becomes commercial marketing.
- Include one screenshot or replay, not a wall of feature images.
- State clearly that this is the author's project and an Alpha.
- Answer every reproducible install problem and move confirmed defects into GitHub Issues.

## Reply Bank

Use these facts to answer common questions. Rewrite them naturally for the discussion instead of pasting them repeatedly.

### Why not just use Codex or Claude Code?

They established the execution-agent category and remain strong coding agents. LingShu explores a different product boundary: the complete native app and runtime are Apache-2.0, the model provider is replaceable, and editable office files plus authorized Mac workflows are first-class deliverables. This is an architectural choice, not a benchmark claim.

### Is everything local?

No. The app, orchestration, task records, artifacts, and authorized computer actions run on the Mac. Selected context is sent to the model endpoint configured by the user. The repository documents these boundaries; “local-first” must not be presented as “no data ever leaves the Mac.”

### Does every model behave the same?

No. The gateway is model-agnostic, but model capability, latency, multimodal support, tool behavior, and output quality vary. LingShu tries native multimodal input first and can remember an incompatibility and use a fallback path, but that is not model parity.

### Why documents and slides?

Many real tasks end in an editable report rather than source code. LingShu treats the file itself as a traceable artifact: create it, register it, preview it, revise it, and verify it before closing the task.

## Owner Action Gates

These actions require the repository owner or an authenticated community account. Automation must stop at the gate and report the exact next action instead of impersonating the owner or bypassing platform controls.

| Gate | Owner action | Continuation after completion |
| --- | --- | --- |
| E2B contributor agreement | Sign the E2B CLA at https://e2b.dev/docs/cla | Comment `@cla-bot check` on [PR #1271](https://github.com/e2b-dev/awesome-ai-agents/pull/1271), then monitor review state |
| GitHub social preview | In repository Settings, upload [`Docs/media/lingshu-social-preview.png`](./media/lingshu-social-preview.png) as the Social preview image | Verify a fresh GitHub share card; GitHub does not expose this setting through the repository REST API |
| GitHub profile metadata | Set name to `Roy Zhao`, bio to `Building LingShu — an Apache-2.0, model-agnostic macOS execution agent.`, and website to https://royzhao1991.github.io/LingShu/ | Confirm the public profile links to the repository; the profile README is already published |
| Reddit launch | Complete account verification and open `r/LLMDevs` while signed in | Recheck the current rule, present the adapted draft for final confirmation, then publish once |
| Hacker News launch | Write the final Show HN title and body personally from the factual worksheet | Check the final text only for factual links and private data; do not generate or rewrite it |

Do not treat an uncompleted owner gate as campaign failure. Continue with reversible repository improvements, review replies, measurement, and other approved channels while the gate remains open.

## Measurement Record

Record one row when a post is published and update it after seven full days.

| Channel | Published at | Repository unique visitors | Release downloads | Stars | Reproducible install reports | Issues / Discussions | External PRs | Decision |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Show HN | Not published | - | - | - | - | - | - | Founder-authored submission required |
| `r/LLMDevs` | Not published | - | - | - | - | - | - | Awaiting account confirmation |
| V2EX `分享创造` | Not published | - | - | - | - | - | - | Awaiting account confirmation |
| `r/ChatGPTCoding` | Not published | - | - | - | - | - | - | Use designated thread only |

Stop or change a channel if two attempts produce clicks without any sample opens, install reports, useful questions, Issues, or contributions. The objective is qualified adoption, not impressions alone.
