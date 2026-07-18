# LingShu Organic Growth Campaign

> Goal: help the right people discover, understand, install, and contribute to LingShu. Stars are a useful signal, but not the product. No paid stars, exchange rings, mass direct messages, or misleading demos.

Canonical public anchors:

- Repository: https://github.com/RoyZhao1991/LingShu
- Website and reproducible sample: https://royzhao1991.github.io/LingShu/
- Alpha announcement and feedback thread: https://github.com/RoyZhao1991/LingShu/discussions/12
- Latest signed release: https://github.com/RoyZhao1991/LingShu/releases/latest

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

The launch copy lives in [`LAUNCH_KIT.md`](./LAUNCH_KIT.md). Adapt the opening paragraph to the community; keep the factual core unchanged.

## 5. Fourteen-Day Sequence

### Day 0 — Positioning reset

- Align README, website metadata, GitHub description, Topics, and social copy.
- Publish one canonical GitHub Discussion explaining why LingShu belongs beside Codex / Claude Code.
- Record the public metric baseline before external distribution.

### Day 1–2 — Technical launch

- Publish the Show HN post with the repository as the primary link.
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

Do not submit another directory-listing pull request until the first one is reviewed or seven days have elapsed. The next independent channel is the technical founder narrative, not another near-identical catalog entry.
