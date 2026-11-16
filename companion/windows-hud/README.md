# PR Review Radar — Windows Sticky Note HUD

A zero-dependency WPF + System Tray desktop sticky-note companion for `@mertbasar0/pr-review-radar`, powered directly by [`pr-radar-engine.mjs`](../../templates/pr-review-radar/workspace/scripts/pr-radar-engine.mjs) and [`resolve-mergeability.mjs`](../../templates/pr-review-radar/workspace/scripts/resolve-mergeability.mjs).

## Features

- **Instant global hotkey (`Ctrl + Alt + R`):** Show or hide the sticky note from any window in 0ms (`Ctrl + Alt + Shift + R` automatic fallback if `Ctrl + Alt + R` is already taken).
- **Color-coded System Tray icon:** Dynamic GDI+ status indicator dot (`#FF4D6D` red when active `P1` blockers/conflicts exist, `#10E88A` green when `P2` PRs are ready to land, `#38BDF8` cyan when idle) with full right-click tray menu.
- **System-locale i18n (`en` / `tr`):** Automatically detects Windows UI culture (`tr` on Turkish Windows, `en` on all other locales) and lets you switch languages live from the tray menu (`🌐 Language / Dil`).
- **Dual themes:** Dark glass HUD and Classic Sticky Yellow note mode.
- **Single-instance launcher (`pr-radar`):** Native `.NET` `WinExe` launcher registers Start Menu shortcut, `Win + R` (`pr-radar`), and User `PATH` (`pr-radar -Toggle`).

## Setup

1. Create `state/config.json`:
   ```json
   {
     "setup": { "ready": true },
     "viewerHandle": "<your-github-login>",
     "repositories": ["openclaw/openclaw"],
     "watchedPaths": ["skills/", "src/templates/"],
     "watchedLabels": [],
     "ignoredChecks": []
   }
   ```
2. Build the `.NET` launcher and register shortcuts (`Win + R` `pr-radar`, Start Menu, optional Startup):
   ```powershell
   pwsh -NoProfile -File .\Install-Shortcuts.ps1
   ```
   *(Or launch directly without building the `.exe`: `pwsh -NoProfile -File .\pr-radar-hud.ps1 -RefreshOnLaunch`)*

To remove shortcuts and `PATH` registration cleanly:

```powershell
pwsh -NoProfile -File .\Install-Shortcuts.ps1 -Uninstall
```
