# LingShu Windows Shell

This directory contains the Windows-specific Tauri and React shell. Platform-independent behavior lives in [`../Runtime/LingShuCore`](../Runtime/LingShuCore); do not duplicate GoalSpec, provider, task-state, artifact, or preview rules in the frontend.

```powershell
npm ci
npm run build
npm run tauri -- dev
npm run tauri -- build
```

See [`../Docs/WINDOWS.md`](../Docs/WINDOWS.md) for the capability boundary and installer workflow.

Prebuilt x64 preview installers are published at [windows-v0.1.0-preview.2](https://github.com/RoyZhao1991/LingShu/releases/tag/windows-v0.1.0-preview.2). The stable setup filename is [`LingShu-Windows-x64-Setup.exe`](https://github.com/RoyZhao1991/LingShu/releases/download/windows-v0.1.0-preview.2/LingShu-Windows-x64-Setup.exe).
