# LingShu Windows Shell

This directory contains the Windows-specific Tauri and React shell. Platform-independent behavior lives in [`../Runtime/LingShuCore`](../Runtime/LingShuCore); do not duplicate GoalSpec, provider, task-state, artifact, or preview rules in the frontend.

```powershell
npm ci
npm run build
npm run tauri -- dev
npm run tauri -- build
```

See [`../Docs/WINDOWS.md`](../Docs/WINDOWS.md) for the capability boundary and installer workflow.
