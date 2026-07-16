# Security Policy / 安全策略

## Supported Versions

Until the first stable release, security fixes target the latest `main` branch and the latest published alpha release. Older development snapshots may not receive fixes.

首个稳定版本发布前，安全修复以最新 `main` 分支和最新公开 Alpha 版本为准，较早的开发快照不承诺持续修复。

## Report a Vulnerability

Do not open a public issue for credential exposure, arbitrary command execution, permission bypass, sandbox escape, unsafe external publication, or private-data disclosure.

Use [GitHub private vulnerability reporting](https://github.com/RoyZhao1991/LingShu/security/advisories/new) and include:

- affected version or commit;
- macOS version and CPU architecture;
- reproducible steps or a minimal proof of concept;
- impact and required permissions;
- suggested mitigation, if known.

请不要用公开 Issue 报告凭据泄漏、任意命令执行、权限绕过、沙盒逃逸、未授权对外发布或隐私数据泄漏。请通过上面的 GitHub 私密漏洞报告入口提交。

## Credential Exposure

Model-provider credentials are stored in macOS Keychain. LingShu migrates the older local encrypted credential file only after each value has been written successfully, then removes that legacy file. Exported configuration bundles are a separate, user-initiated operation and must remain encrypted with the user-provided export password.

模型服务凭据保存在 macOS 钥匙串中。旧版本的本地加密凭据文件只会在每项凭据成功写入钥匙串后删除。配置导出属于用户主动操作，导出包必须继续使用用户提供的口令加密。

If a real token or signing credential is ever committed:

1. revoke or rotate it immediately;
2. remove it from the current tree and Git history;
3. inspect logs, releases, caches, and forks for copies;
4. document the incident without republishing the secret.

Deleting a secret only from the latest commit is not sufficient.

## Trust Boundaries

- LingShu processes live sensory streams in memory and does not archive raw streams by default.
- Data sent to a configured remote model, perception provider, website, or external agent leaves the Mac and follows that provider's terms.
- Native Computer Use requires explicit macOS permissions and should operate with the smallest practical authorization scope.
- Plugins, scripts, model tools, and external agents can execute code or transmit data. Treat unreviewed third-party capabilities as untrusted.
- Users remain responsible for reviewing high-impact actions and maintaining backups.

## Disclosure

The maintainer will acknowledge actionable reports when possible, investigate privately, prepare a fix, and coordinate disclosure after affected users have a reasonable upgrade path.
