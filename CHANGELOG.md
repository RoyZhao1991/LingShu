# Changelog

All notable changes to LingShu will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and released versions will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) where practical during the alpha period.

## [Unreleased]

No unreleased changes have been recorded yet.

## [0.1.0-alpha] - 2026-07-15

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
- Apache License 2.0 and third-party attribution.
- Contribution, security, and community conduct policies.
- Structured issue forms, pull request template, CODEOWNERS, Dependabot, and macOS CI.
- Public-release and 30-day open-source operations playbook.

### Changed

- Clarified the privacy boundary between in-memory local perception and content sent to configured remote providers.
- Isolated the 220-case full-stack test from a user's persisted world model and task journal.
- Replaced model-specific GoalSpec recovery with protocol-tolerant generation and validation policies.
- Kept the main conversation serialized while allowing delegated work to run and report through isolated task state.

[Unreleased]: https://github.com/RoyZhao1991/LingShu/compare/v0.1.0-alpha...HEAD
[0.1.0-alpha]: https://github.com/RoyZhao1991/LingShu/releases/tag/v0.1.0-alpha
