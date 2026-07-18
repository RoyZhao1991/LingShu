# LingShu Organic Growth Campaign

> Goal: help the right people discover, understand, install, and contribute to LingShu. Stars are a useful signal, but not the product. No paid stars, exchange rings, mass direct messages, or misleading demos.

Canonical public anchors:

- Repository: https://github.com/RoyZhao1991/LingShu
- Website and reproducible sample: https://royzhao1991.github.io/LingShu/
- Alpha announcement and feedback thread: https://github.com/RoyZhao1991/LingShu/discussions/12
- Latest signed release: https://github.com/RoyZhao1991/LingShu/releases/tag/v0.1.0-alpha.6
- Privacy-safe first-run report: https://github.com/RoyZhao1991/LingShu/issues/new?template=first_run_report.yml

## 1. Category and Message

LingShu should always enter the conversation through the execution-agent category:

> LingShu is an Apache-2.0, model-agnostic macOS execution agent in the Codex / Claude Code category. Bring your own model and deliver verified code, documents, slides, and authorized computer actions through one open runtime.

中文：

> 灵枢是一套与 Codex / Claude Code 同类的 macOS 执行型 Agent：完整 App 与运行时采用 Apache-2.0 开源，主脑可替换，代码、文档、PPT 与授权后的电脑操作共用同一能力层。

Message order matters:

1. Same category as Codex / Claude Code: execution, tools, long-running work, and real deliverables.
2. Complete native app and runtime are open source, not only a plugin or thin integration.
3. The model is a replaceable dependency: OpenAI, Claude, DeepSeek, MiniMax, or a compatible endpoint.
4. Code is one deliverable, not the boundary: editable office files and authorized Mac workflows use the same runtime.
5. Completion is evidence-based: real artifacts, preview, task records, and an independent checker.

Do not lead with perception, voice, self-evolution, test counts, or a long feature inventory. They support trust after the core distinction is understood.

## 2. Audiences

| Audience | Existing pain | Proof that earns attention | Primary action |
| --- | --- | --- | --- |
| Codex / Claude Code power users | Model or product-surface lock-in; coding-only default scope | Provider-neutral gateway, full runtime source, real artifact workflow | Inspect source and architecture |
| Local-first and open-source AI builders | Agent behavior hidden behind hosted products | Apache-2.0 Swift runtime, local task records, explicit permissions | Star, install, open an issue |
| macOS automation users | Scripts and UI automation lack planning, memory, and verification | Native Computer Use plus human checkpoints and task records | Install signed alpha |
| Report-heavy technical teams | AI produces copy or outlines but not a dependable final file | Reproducible PPTX/DOCX/PDF sample with revision history | Inspect Project Aurora |
| Potential contributors | Large agent projects are hard to enter | Architecture guide, tests, scoped starter issues | Pick a `good first issue` |

## 3. Conversion Funnel

Every public post should send people through one short path:

1. **Recognize the category** — “open-source, model-agnostic execution agent for macOS.”
2. **See one proof** — a 60–90 second real run or the Project Aurora editable sample.
3. **Trust the boundary** — alpha status, permissions, model-provider disclosure, signed and notarized DMG.
4. **Try one command** — `brew install --cask RoyZhao1991/tap/lingshu`.
5. **Reach one success** — create and verify a one-page local document.
6. **Leave a durable signal** — Star, reproducible issue, install report, discussion, or pull request.

The GitHub README and official site are the canonical landing pages. Channel posts should not reproduce the whole feature list.

## 4. Channel Plan

| Channel | Angle | Format | Publication rule | Success signal |
| --- | --- | --- | --- | --- |
| GitHub | Canonical announcement and transparent alpha status | Pinned Discussion + release notes | Publish first; answer every substantive reply | Stars, issue quality, external participants |
| Hacker News | Open agent architecture beyond coding | Show HN with technical founder narrative | Post once, preferably US morning Tue–Thu; stay present for comments | Engaged technical discussion, unique visitors |
| Reddit | Model-agnostic local agent and real macOS workflow | Tailored post for each community | Read each community rule; never copy-paste across subreddits on one day | Saves, questions, reproducible installs |
| X / LinkedIn | Founder build story plus 20–40 second visual proof | Short post + demo clip | One clear claim and one link; reply with architecture/sample details | Qualified profile visits and repository clicks |
| V2EX / 掘金 / 即刻 | 国产模型可接入、完整开源、真实交付物 | 中文技术长帖 + 样例截图 | Use a native Chinese narrative; disclose Alpha limitations | 中文安装反馈、Issue、Star |
| Product Hunt | Polished installable macOS product | Product page, gallery, demo | Launch only after the demo and clean first-run proof are ready | Install attempts and retained users, not rank alone |

The factual launch material lives in [`LAUNCH_KIT.md`](./LAUNCH_KIT.md). Channel-native drafts, publication gates, and measurement records live in [`COMMUNITY_LAUNCH_PACK.md`](./COMMUNITY_LAUNCH_PACK.md). Adapt the opening and requested feedback to the community; never copy-paste one post across channels.

### First external wave

The first wave uses three channels with different audiences instead of repeating the same directory submission:

| Channel | Why it fits | Native message | State |
| --- | --- | --- | --- |
| [`awesome-mac`](https://github.com/jaywcjlove/awesome-mac) | More than 100,000 developers and macOS users; active AI Tools curation and frequent merges | Native macOS execution agent, signed app, complete Apache-2.0 source | [PR #2355](https://github.com/jaywcjlove/awesome-mac/pull/2355) open and mergeable |
| [E2B Awesome AI Agents](https://github.com/e2b-dev/awesome-ai-agents) | Agent-specific discovery surface with more than 28,000 GitHub Stars | Open, model-agnostic execution runtime with real artifact delivery and human checkpoints | [PR #1271](https://github.com/e2b-dev/awesome-ai-agents/pull/1271) open and mergeable; owner CLA signed and bot recheck completed |
| Hacker News | Strong fit for architecture, open-source runtime, and model-provider discussion | Founder narrative: what changes when the native app and runtime are open and the model becomes replaceable | Founder must write the final post personally; HN disallows generated or AI-edited submission text |
| `r/LLMDevs` | Explicitly permits free open-source projects and reaches developers working on LLM infrastructure | Provider-neutral runtime, human checkpoints, and artifact verification | Native draft prepared; account confirmation required before posting |
| V2EX `分享创造` | Explicitly welcomes independent developers sharing new work with early adopters | Complete runtime open source, domestic and overseas model endpoints, and real PPTX/DOCX delivery | Native draft prepared; account confirmation required before posting |

The following high-Star lists were reviewed but deliberately not used in this wave:

- `kyrolabs/awesome-agents` asks brand-new projects to demonstrate traction before submission.
- `ai-boost/awesome-harness-engineering` currently has more than 130 open pull requests and low merge throughput for outside additions.
- `deepseek-ai/awesome-deepseek-integration` is highly relevant, but has a large open-PR backlog and slow batch merges; revisit after the first launch wave produces usage evidence.

### Discovery and first-value hardening

The second wave improves the path from an organic search or profile visit to a successful first task:

- GitHub Topics now lead with the execution-agent category (`coding-agent`, `ai-agent`, `computer-use`, and `macos-app`) instead of implying affiliation with a model vendor.
- The maintainer profile at [`RoyZhao1991/RoyZhao1991`](https://github.com/RoyZhao1991/RoyZhao1991) gives visitors a direct, factual route to LingShu.
- The official site publishes `SoftwareApplication` structured data and [`llms.txt`](https://royzhao1991.github.io/LingShu/llms.txt) with verified facts, boundaries, and reproducible evidence.
- Both READMEs give new users one small first task that exercises file creation, artifact registration, preview, and independent verification before broad computer permissions are granted.
- The first task now ends in one structured [Alpha first-run report](https://github.com/RoyZhao1991/LingShu/issues/new?template=first_run_report.yml), including success, partial success, and failure instead of counting downloads as installations.
- The repository social preview asset is ready at [`Docs/media/lingshu-social-preview.png`](./media/lingshu-social-preview.png); GitHub requires a repository owner to upload it from Settings.

#### E2B directory submission

- **Product:** LingShu
- **Tagline:** `Open macOS agent for verified deliverables`
- **Type:** Open-source
- **Categories:** General purpose; Content creation; Coding; Productivity; Multi-agent; Supports open-source models
- **Additional category:** Computer use; document and presentation delivery
- **Website:** https://royzhao1991.github.io/LingShu/
- **GitHub:** https://github.com/RoyZhao1991/LingShu
- **Proof:** https://royzhao1991.github.io/LingShu/#deliverables
- **Release:** https://github.com/RoyZhao1991/LingShu/releases/tag/v0.1.0-alpha.6

Description:

> LingShu is an Apache-2.0, model-agnostic native macOS execution agent in the Codex / Claude Code category. Users bring OpenAI, Anthropic, DeepSeek, MiniMax, or a compatible endpoint while the same open runtime plans long-running work, runs isolated workers and tools, registers real artifacts, pauses for human action, and sends results to an independent checker. Code is one deliverable, not the boundary: LingShu also creates editable PPTX, DOCX, PDF, media, and authorized Mac workflows.

## 5. Fourteen-Day Sequence

### Day 0 — Positioning reset

- Align README, website metadata, GitHub description, Topics, and social copy.
- Publish one canonical GitHub Discussion explaining why LingShu belongs beside Codex / Claude Code.
- Record the public metric baseline before external distribution.

### Day 1–2 — Technical launch

- The founder writes and publishes the Show HN post in their own words with the repository as the primary link. Do not use generated or AI-edited submission text.
- Stay available for at least two hours after publication; answer architecture, safety, licensing, and model-compatibility questions directly.
- Turn repeated objections into README clarifications or Issues within 24 hours.

### Day 3–5 — Audience-specific proof

- Publish one local/open-source AI post focused on the model-agnostic runtime.
- Publish one macOS post focused on signed distribution, permissions, and native Computer Use.
- Do not publish identical text; each post must answer that community's actual concern.

### Day 6–7 — Chinese launch

- Publish the Chinese technical long post with the same comparison discipline.
- Lead with “完整运行时开源 + 主脑可替换 + 不只交付代码,” then link the reproducible sample and signed release.
- Report the first seven days honestly, including failed channels and install friction.

### Day 8–14 — Proof iteration

- Release the 60–90 second real demo in English and Chinese subtitles.
- Publish one technical teardown: GoalSpec → isolated worker → artifact ledger → checker.
- Keep only channels that produced repository visits, installs, useful issues, or contributors.

## 6. Measurement

Record these once per day during launch week and weekly afterward:

| Metric | Why it matters | Interpretation guardrail |
| --- | --- | --- |
| Repository unique visitors | Reach | A visit is not product interest by itself |
| Stars / unique visitors | Positioning conversion | Compare week over week, not hour by hour |
| Unique cloners | Technical intent | Cloning is not a successful build |
| Release asset downloads | Install intent | A download is not a successful launch |
| Reproducible install reports | First-value evidence | Count only explicit successful or failed attempts |
| External Issues / Discussions | Engagement quality | Prefer specific feedback over volume |
| External pull requests | Contribution health | Track review and merge time |
| Channel referrers / platform link clicks | Distribution quality | Use aggregate data only; no user-level tracking |

Current baseline is maintained in [`OPEN_SOURCE_BASELINE.md`](./OPEN_SOURCE_BASELINE.md). The first experiment is the positioning reset from “desktop AI beyond chat” to “open-source, model-agnostic execution agent beside Codex / Claude Code.” Evaluate it after seven full days, not after the first post.

## 7. Response Operations

- Installation, startup, permissions, model setup, and crashes receive first response within 24 hours during launch week.
- Answer comparisons with evidence and links; never attack Codex, Claude Code, or their communities.
- Convert a reproducible defect into an Issue and link it from the original discussion.
- Thank outside contributors publicly after their work merges.
- Publish limitations before they are discovered by users whenever possible.
- If a channel produces clicks but no installs or useful discussion twice, stop posting there and improve the landing or proof instead.

## 8. Non-Negotiable Integrity Rules

- Never buy, exchange, script, or pressure people for Stars.
- Never mass-message strangers or post the same promotional copy into unrelated communities.
- Never imply Codex CLI is closed source or that Claude Code source cannot be viewed.
- Never claim model parity, production readiness, complete autonomy, or successful installation without evidence.
- Never expose private prompts, paths, account data, credentials, or user history in public media.

The durable growth loop is: **clear category → inspectable proof → successful first run → responsive maintenance → contribution → stronger proof**.

## 9. Distribution Log

| Date | Channel | Public action | Measurement window |
| --- | --- | --- | --- |
| 2026-07-18 | GitHub Discussions | Published the canonical bilingual alpha announcement in [Discussion #12](https://github.com/RoyZhao1991/LingShu/discussions/12) | Seven days |
| 2026-07-18 | Curated macOS directory | Submitted a bilingual AI-category listing to [`awesome-swift-macos-apps` PR #76](https://github.com/jaywcjlove/awesome-swift-macos-apps/pull/76) | From merge until seven days after merge |
| 2026-07-18 | Repository + website | Published a 16-second captioned replay from a real Project Aurora task record: explicit goal, registered PPTX/DOCX artifacts, and independent review | Compare repository visits, sample opens, release downloads, and qualified discussion over seven days |
| 2026-07-18 | GitHub Discussions | Added the replay as a focused proof update in [Discussion #12](https://github.com/RoyZhao1991/LingShu/discussions/12#discussioncomment-17679576), linking directly to the website's deliverables section | Seven days; do not repost the same update elsewhere without adapting it to that audience |
| 2026-07-18 | `awesome-mac` AI Tools | Submitted a concise, factual LingShu listing in English, Chinese, Japanese, and Korean through [PR #2355](https://github.com/jaywcjlove/awesome-mac/pull/2355) | Track review/merge time; after merge, compare GitHub referrers, site visits, release downloads, and outside feedback for seven days |
| 2026-07-18 | E2B Awesome AI Agents | Submitted an agent-category listing with verified website, release, task replay, and reproducible artifact links through [PR #1271](https://github.com/e2b-dev/awesome-ai-agents/pull/1271) | Complete the owner-only CLA signature, then track review/merge time and seven-day repository referrers, release downloads, Stars, and outside feedback |
| 2026-07-18 | Community launch operations | Prepared channel-native publication gates and drafts for `r/LLMDevs` and V2EX `分享创造`, plus a founder-only Show HN worksheet in [`COMMUNITY_LAUNCH_PACK.md`](./COMMUNITY_LAUNCH_PACK.md) | Publish one channel at a time with account confirmation; measure each for seven full days |
| 2026-07-18 | GitHub discovery | Replaced vendor-like Topics with execution-agent and native macOS discovery terms; published a maintainer profile README that routes visitors to LingShu | Compare profile and search referrers over seven days; keep only accurate category terms |
| 2026-07-18 | Website and first run | Added verifiable `SoftwareApplication` metadata, `llms.txt`, and a one-document first-task path in both READMEs | Confirm Pages deployment, then track sample opens, installation questions, and first-task reports rather than impressions alone |
| 2026-07-19 | `awesome-mac` maintainer amplification | Maintainer [publicly shared LingShu on X](https://x.com/jaywcjlove/status/2078476842005356908) while reviewing [PR #2355](https://github.com/jaywcjlove/awesome-mac/pull/2355); shortened all four localized descriptions in response | Treat as one verified external amplification; track referred visits and first-run reports without attributing unrelated traffic |
| 2026-07-19 | `Jenqyang/Awesome-AI-Agents` | [PR #388](https://github.com/Jenqyang/Awesome-AI-Agents/pull/388) closed without merge because the two-day-old Alpha lacked independent usage and maintenance history | Record as channel feedback, not a success; resubmit only after meaningful outside usage exists |
| 2026-07-19 | Repository, README, and website | Added a privacy-safe 15-minute Alpha first-run Issue form and linked it directly after the canonical first task | Count explicit successful, partial, and failed outside reports; do not infer success from downloads or clones |

Daily open-source growth operations now check metrics, distribution gates, review feedback, and one concrete channel action. Do not submit another general-purpose directory pull request until PR #76 and PR #2355 are reviewed or seven days have elapsed. E2B PR #1271 is the separate agent-product submission surface, and community launches must not reuse directory wording verbatim.
