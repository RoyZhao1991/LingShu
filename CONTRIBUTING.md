# Contributing to LingShu

[English](#english) | [简体中文](#简体中文)

## English

Thank you for helping make LingShu more useful, reliable, and understandable. Focused contributions with reproducible evidence are especially valuable.

### Before You Start

1. Search existing issues and pull requests.
2. For a large architectural change, open a proposal issue first.
3. Never include API tokens, Apple credentials, private logs, personal files, or model-provider secrets.
4. Keep changes scoped. Do not combine a feature, broad refactor, and formatting sweep in one pull request.

### Local Setup

Requirements: macOS 14+, Xcode Command Line Tools, and Swift 6.

```bash
git clone https://github.com/RoyZhao1991/LingShu.git
cd LingShu
swift test
bash Scripts/build-app.sh debug
open "dist/灵枢.app"
```

Use dummy credentials in tests. Environment-dependent or paid-provider tests must be opt-in and clearly documented.

### Pull Request Checklist

- Explain the user problem and the chosen design.
- Add or update tests proportional to the behavioral risk.
- Run `swift test`, or state exactly which tests could not run and why.
- Update the canonical architecture field guide when behavior or module ownership changes.
- Include screenshots for visible UI changes and verify both light and dark appearance when relevant.
- Preserve existing permission, confirmation, redaction, and artifact-verification boundaries.
- Avoid model-specific exceptions when a protocol- or capability-based solution is possible.

### Review and Recognition

Every outside pull request is reviewed before merge. The review covers scope, user-visible behavior, regressions, security and privacy boundaries, internationalization, documentation, and tests proportional to risk. A pull request is merged only after the required evidence and CI checks pass; activity alone is never a reason to merge incomplete work.

When a contribution is merged, LingShu preserves the contributor's Git authorship, posts a specific public thank-you on the pull request, and records the contribution in the relevant release notes or project operations record. Review may still request changes or decline work that does not fit the current architecture or roadmap.

By submitting a contribution, you agree that it is licensed under the repository's Apache License 2.0.

## 简体中文

感谢你帮助灵枢变得更可靠、更实用、更容易理解。我们尤其欢迎范围清晰、能够复现并带验证依据的贡献。

### 开始之前

1. 先搜索已有 Issue 和 Pull Request。
2. 大型架构改动请先提交方案 Issue 讨论。
3. 禁止提交 API Token、Apple 凭据、私人日志、个人文件或模型服务商密钥。
4. 保持改动聚焦，不要把新功能、大范围重构和格式清理混在一个 PR 中。

### 提交要求

- 说明用户问题与设计取舍。
- 按行为风险补充或更新测试。
- 运行 `swift test`；若无法执行，明确写出未运行的测试及原因。
- 行为或模块边界发生变化时，同步更新架构速查手册。
- 可见 UI 改动附截图，并按需检查浅色与深色模式。
- 保留现有权限、确认、脱敏与交付物验收边界。
- 能用协议或能力判断解决时，不为单一模型增加特殊分支。

### 审查与贡献记录

所有外部 Pull Request 都会在合并前接受完整审查，范围包括改动边界、用户可见行为、回归风险、安全与隐私边界、国际化、文档，以及与风险相匹配的测试。只有验证依据充分且 CI 检查通过后才会合并；不会为了制造活跃度而合并不完整的代码。

贡献合并后，灵枢会保留贡献者的 Git 作者身份，在 Pull Request 中公开说明并感谢具体贡献，并将其记录到对应版本说明或项目运营记录中。若改动不符合当前架构或路线，审查仍可能要求修改或不予合并。

提交贡献即表示你同意按本仓库 Apache License 2.0 授权该贡献。
