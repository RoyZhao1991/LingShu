# Changelog

All notable changes to LingShu will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and released versions will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) where practical during the alpha period.

## [Unreleased]

### Changed

- Public releases now verify DMG integrity before notarization and clean up exact-image DiskImages attachments left by interrupted notarization attempts.
- The release pipeline supports a configurable non-S3 notarization upload path for networks where accelerated upload is unreliable.

## [0.1.0-alpha.8] - 2026-07-19

### Added

- A notarized-DMG clean-user smoke path that isolates home, Application Support, preferences, temporary files, credentials, task history, permission services, and background services.
- Machine-readable release evidence for first-language selection, no-brain setup, app liveness, installed signature, no-permission startup, empty history, and a deterministic minimal reply.

## [0.1.0-alpha.7] - 2026-07-19

### Added

- A 71-second privacy-safe end-to-end demo showing synthetic PPTX/DOCX delivery, independent checking, and artifact registration, with accelerated waits and second-run inspection footage explicitly disclosed.

### Fixed

- Filename-only delivery replies now register real task outputs from trusted task directories without requiring the model to expose absolute local paths.
- Artifact reconciliation excludes user-authored filename mentions, rejects symbolic links, canonicalizes trust checks, and suppresses duplicate entries.

## [0.1.0-alpha.6] - 2026-07-18

### Added

- A privacy-safe, reproducible Project Aurora sample with editable PPTX and DOCX deliverables, a rendered PDF, page previews, and an honest revision record.

### Fixed

- Light-mode command approval text now uses adaptive foreground colors instead of unreadable white text.
- Built-in task participant and role filters now follow the selected interface language without changing persisted actor identifiers.

## [0.1.0-alpha] - 2026-07-18

First public alpha.

### Added

- Native macOS agent runtime with structured GoalSpec generation, execution planning, tool loops, interruption, resume, and completion gates.
- Isolated worker sessions, child-task activity tracking, distilled completion memory, independent checking, and artifact registration.
- OpenAI, Anthropic Claude, DeepSeek, MiniMax M3, and custom compatible brain routes with first-run setup guidance.
- Native Accessibility-based Computer Use with indexed UI actions, screen fallback, and post-action verification; Codex is optional rather than required.
- Multimodal attachment routing that tries model-native vision first and remembers when a channel requires image-parsing fallback.
- Local task history, knowledge graph, procedure replay, perception surfaces, voice paths, and external-agent integration presets.
- Universal Developer ID signing, Apple notarization, stapled DMG, checksum, and machine-readable release manifest pipeline.
- English-first and complete Simplified Chinese project introductions.
- First-launch language selection and bilingual setup surfaces.
- Mutable, persisted runtime workflow graphs that let the model add, replace, reorder, retry, or skip still-pending execution nodes without changing the GoalSpec or acceptance boundary.
- A typed human-collaboration protocol for questions, choices, forms, QR/login steps, physical actions, file selection, confirmation, manual completion, HTTP probes, and file probes.
- Exact-session resume for workers and checkers, including a third `needs_human_interaction` verification outcome that does not misreport human participation as failure.
- A bundled `lingshu` CLI for one-request/one-response access from Feishu bots, webhooks, Shortcuts, and local automation, reusing the serialized main session and exact human-interaction checkpoints.
- Apache License 2.0 and third-party attribution.
- Contribution, security, and community conduct policies.
- Structured issue forms, pull request template, CODEOWNERS, Dependabot, and macOS CI.
- Public-release and 30-day open-source operations playbook.

### Changed

- Clarified the privacy boundary between in-memory local perception and content sent to configured remote providers.
- Isolated the 220-case full-stack test from a user's persisted world model and task journal.
- Replaced model-specific GoalSpec recovery with protocol-tolerant generation and validation policies.
- Kept the main conversation serialized while allowing delegated work to run and report through isolated task state.
- Model credentials use macOS Keychain as the primary store; legacy local credential files migrate only after every entry is safely persisted.
- OAuth authorization cards remain driven exclusively by the structured OAuth marker, while generic human interaction follows its own app-native protocol.
- Dynamic workflow mutations are validated as a transaction, reject dependency cycles and started-node rewrites, and persist their revision history in the task record.
- Read-only agent stalls now receive a final model-owned, tool-free convergence turn instead of exposing internal process output or hard-coded diagnostic prose.

[Unreleased]: https://github.com/RoyZhao1991/LingShu/compare/v0.1.0-alpha.8...HEAD
[0.1.0-alpha.8]: https://github.com/RoyZhao1991/LingShu/releases/tag/v0.1.0-alpha.8
[0.1.0-alpha.7]: https://github.com/RoyZhao1991/LingShu/releases/tag/v0.1.0-alpha.7
[0.1.0-alpha.6]: https://github.com/RoyZhao1991/LingShu/releases/tag/v0.1.0-alpha.6
[0.1.0-alpha]: https://github.com/RoyZhao1991/LingShu/releases/tag/v0.1.0-alpha
