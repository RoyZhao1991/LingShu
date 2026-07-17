# First Public Issues / 首批公开 Issue 候选

These candidates create concrete contribution paths before the repository becomes public. Recheck the current code before opening an issue so completed work is not requested again.

这些候选用于仓库公开前建立真实、可贡献的工作入口。创建 Issue 前应再次核对现状，不把已经完成的内容重复发布。

## Good First Issues

### 1. Add an English troubleshooting page for first-run macOS permissions

**Goal:** Document when Accessibility, Screen Recording, Microphone, Speech Recognition, and Camera permissions are requested, how a denied permission appears, and how to recover through macOS settings.

**Acceptance:**

- Covers every permission currently requested by the app.
- Links each permission to the capability that needs it.
- Includes safe recovery steps without suggesting any permission bypass.
- Uses screenshots or labels that match the current macOS version where practical.

**中文摘要：**补充英文首次权限排障页，说明权限触发时机、失败表现和安全恢复方式，不得建议绕过系统权限。

**Labels:** `documentation`, `good first issue`

### 2. Add a provider-neutral model configuration diagnostics export

**Goal:** Export a small diagnostics report covering endpoint reachability, protocol family, selected model, capability state, and redacted errors for both OpenAI-compatible and Anthropic Messages channels.

**Acceptance:**

- Never exports API tokens, authorization headers, or unredacted request bodies.
- Works without branching on a provider or model name.
- Distinguishes connection, authentication, protocol, model, and capability failures.
- Includes focused tests using synthetic credentials and offline fixtures.

**中文摘要：**增加服务商无关的模型配置诊断导出，覆盖端点、协议、模型和脱敏错误，不能包含 Token，也不能按模型名称硬编码。

**Labels:** `enhancement`, `good first issue`, `area: model-gateway`

### 3. Improve third-party notice discovery during release builds

**Goal:** Add a deterministic release check that identifies new bundled resource directories and requires their license or notice status to be explicitly reviewed.

**Acceptance:**

- Fails with an actionable message when a bundled third-party resource lacks attribution.
- Allows original project assets to be declared without pretending they are third-party packages.
- Keeps the existing Lucide ISC/MIT notice intact.
- Runs locally without network access.

**中文摘要：**让发布检查确定性发现新增资源的 LICENSE/NOTICE 缺口；缺失归属时发布失败，且保留现有 Lucide 声明。

**Labels:** `documentation`, `good first issue`

## Help Wanted

### 4. Create a privacy-safe demo profile and screenshot capture workflow

**Goal:** Add a demo-data mode that can produce README screenshots and release videos without reading real chat, task, memory, account, or user-directory data.

**Acceptance:**

- Demo records are clearly marked as samples in the UI or fixture source.
- Starting demo mode does not load existing user history.
- Resetting demo mode removes only demo data.
- The workflow documents how to verify screenshots before publication.

**中文摘要：**提供隔离的演示数据模式和截图流程，不能读取真实聊天、任务、记忆、账户或用户目录数据。

**Labels:** `enhancement`, `help wanted`

### 5. Split CI into fast pull-request checks and the complete 1,500+ test suite

**Goal:** Keep pull-request feedback fast while preserving the complete suite as a mandatory main-branch, scheduled, or manually triggered verification path.

**Acceptance:**

- The fast lane covers architecture guards, model protocols, task lifecycle, permissions, and acceptance gates.
- The complete lane discovers and executes the full SwiftPM suite without relying on a hard-coded test count.
- Neither lane silently converts failures into skips or success.
- CI documentation explains when each lane runs.

**中文摘要：**拆分 PR 快速门和完整测试门；快速门覆盖关键内核，完整门动态发现并保留全部 1,500+ 项测试，任何失败都不能静默跳过。

**Labels:** `enhancement`, `help wanted`

### 6. Add clean-machine installation smoke automation

**Goal:** Automate a repeatable smoke path for source build, first launch, missing-brain onboarding, denied-permission behavior, and one minimal direct-answer task.

**Acceptance:**

- Does not depend on a maintainer path, account, or credential.
- Separates offline checks from tests that require an explicitly supplied model token.
- Cleans up temporary application data created by the smoke run.
- Produces a concise failure report suitable for an issue attachment.

**中文摘要：**增加干净环境安装冒烟，覆盖源码构建、首次启动、主脑引导、未授权状态和最小直答，不依赖维护者个人环境。

**Labels:** `enhancement`, `help wanted`

### 7. Add protocol contract fixtures for model providers

**Goal:** Expand offline contract fixtures for OpenAI Responses, Chat Completions, Anthropic Messages, streaming, multimodal trial, and remembered capability fallback.

**Acceptance:**

- Uses recorded or synthetic protocol fixtures with no live secret.
- Tests native multimodal trial before fallback and remembered unsupported capability state.
- Never decides capability support from a model-name allowlist or denylist.
- Covers malformed and partial streaming responses.

**中文摘要：**为各协议、流式和多模态尝试/降级补充脱网契约测试，禁止按模型名称判断能力。

**Labels:** `enhancement`, `help wanted`, `area: model-gateway`

### 8. Benchmark native Computer Use on a reproducible app set

**Goal:** Define a public benchmark across Finder, TextEdit, Safari, or a purpose-built test host and report semantic targeting success, action verification, fallback count, and latency.

**Acceptance:**

- Uses tasks that another contributor can reproduce on a clean Mac.
- Separates Accessibility-tree targeting from screen-based fallback.
- Records failures and permission state instead of reporting only successful runs.
- Publishes the benchmark environment and raw result schema.

**中文摘要：**为原生 Computer Use 建立可复现基准，分别记录语义定位、动作验证、视觉回退、失败和延迟。

**Labels:** `enhancement`, `help wanted`, `area: computer-use`

## Maintainer-Owned Launch Blockers

### 9. Publish the first signed and notarized Universal DMG

**Goal:** Produce the public website-distribution package from the final green commit.

**Acceptance:**

- Developer ID signature validates for the app and DMG contents.
- Apple notarization succeeds and the ticket is stapled.
- SHA-256 checksum is published next to the DMG.
- Installation and rollback are verified outside the development checkout.

**中文摘要：**从最终绿色提交生成 Universal DMG，完成 Developer ID 签名、Apple 公证、票据装订、校验和及安装回滚验证。

**Labels:** `alpha feedback`

### 10. Produce a 60-90 second end-to-end launch demo

**Goal:** Record one real, reproducible, privacy-safe task from request to verified artifact.

**Acceptance:**

- Shows brain setup only if no token or account data is visible.
- Shows GoalSpec, execution or Computer Use, artifact registration, independent verification, and final preview.
- Uses isolated demo data and contains no private notification, path, credential, or account detail.
- Provides English and Chinese subtitles from the same source recording.

**中文摘要：**用一条真实任务展示目标、执行、产物、独立验收和预览，使用隔离数据并提供中英文字幕。

**Labels:** `documentation`, `alpha feedback`
