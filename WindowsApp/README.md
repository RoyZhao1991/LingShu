# LingShu Windows Shell

This directory contains the Windows-specific Tauri and React shell. Platform-independent behavior lives in [`../Runtime/LingShuCore`](../Runtime/LingShuCore); do not duplicate GoalSpec, provider, task-state, artifact, or preview rules in the frontend.

```powershell
npm ci
npm run build
npm run tauri -- dev
npm run tauri -- build
```

See [`../Docs/WINDOWS.md`](../Docs/WINDOWS.md) for the capability boundary and installer workflow.
The shared local plugin package contract is documented in
[`../Docs/PLUGIN_SDK.md`](../Docs/PLUGIN_SDK.md). The built-in DesignKB plugin
is bundled as a self-contained Windows resource and requires no separate Python
installation in release builds. The same shared core can register unmodified
Codex, Claude Code, and Open Agent Skills `SKILL.md` directories and load their
instructions and resources progressively; importing a Skill never executes its
scripts automatically.

Conversation messages can be copied, while user messages can be restored with their recorded attachments into the composer for editing and explicit resend. These actions never send automatically or rewrite prior history.

The Memory page manages the shared Runtime Core's real long-term store with search, filters, create/edit/delete, optimistic concurrency protection, and explicit reveal for one sensitive item at a time. The branded setup executable preserves upgrades from legacy publisher registry paths, while application data remains outside the app install directory. Installer and application metadata identify the publisher as Roy Zhao; the preview remains unsigned, so Windows may still show an unknown-publisher or SmartScreen warning.

Prebuilt x64 preview installers are published at [windows-v0.1.0-preview.27](https://github.com/RoyZhao1991/LingShu/releases/tag/windows-v0.1.0-preview.27). The stable setup filename is [`Nous-Windows-x64-Setup.exe`](https://github.com/RoyZhao1991/LingShu/releases/download/windows-v0.1.0-preview.27/Nous-Windows-x64-Setup.exe).
