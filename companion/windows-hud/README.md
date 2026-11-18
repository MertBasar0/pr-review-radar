# PR Review Radar — Windows Sticky Note HUD

A compact WPF + System Tray desktop sticky-note companion for `@mertbasar0/pr-review-radar`, powered by [`pr-radar-engine.mjs`](../../templates/pr-review-radar/workspace/scripts/pr-radar-engine.mjs), [`resolve-mergeability.mjs`](../../templates/pr-review-radar/workspace/scripts/resolve-mergeability.mjs), and [`watch-and-vet-engine.mjs`](../../templates/pr-review-radar/workspace/scripts/watch-and-vet-engine.mjs).

## Features

- **Compact Sticky HUD + Instant Global Hotkey (`Ctrl + Alt + R`):** Show or hide the sticky note from any window in 0ms (`Ctrl + Alt + Shift + R` automatic fallback).
- **In-HUD Surface Focus & Collapsible Brief:** Enter any area/topic in the top input bar to have your local AI agent (`OpenClaw`, `Codex`, `Gemini`, `Claude`, or `Ollama`) scan all-time PR/issue/commit history, re-aim radar focus automatically, and generate a **collapsible** brief (current state commentary, contribution opportunities, and active developers) without expanding your compact HUD footprint.
- **Tracked Delta Watcher & 5-Gate Candidate Vetter (`ADAY / İZLEME`):** Surfaces real-time deltas on tracked PRs/issues and vets unclaimed `clawsweeper:queueable-fix` candidates across all 5 collision gates, highlighting priority ownership areas (`⭐ ÖNCELİKLİ ALAN`).
- **One-Click Preview `clawhandoff` + Ownership Claim:** Pick any vetted candidate, preview/edit the GitHub claim comment and target local coding agent inline, and confirm once to launch an isolated `clawhandoff` worktree session + post the ownership comment safely.
- **Color-coded System Tray icon & Dual Themes:** Dynamic GDI+ tray status dot (`#FF4D6D` red `P1`, `#10E88A` green `P2`, `#F59E0B` amber candidates, `#38BDF8` cyan idle), Dark Neon / Sticky Yellow themes, and live `en` / `tr` switching.

## Setup

1. Create `state/config.json`:
   ```json
   {
     "setup": { "ready": true },
     "viewerHandle": "<your-github-login>",
     "repositories": ["openclaw/openclaw"],
     "focusTopic": "",
     "watchedPaths": ["skills/", "src/templates/"],
     "watchedLabels": [],
     "watchedKeywords": [],
     "ignoredChecks": [],
     "watch": {
       "enabled": true,
       "repo": "openclaw/openclaw",
       "vetCandidates": true,
       "candidateLabel": "clawsweeper:queueable-fix",
       "priorityLabels": ["impact:auth-provider"],
       "priorityKeywords": ["subagent", "subagents", "sessions_spawn"]
     },
     "handoff": {
       "clawhandoffPath": "<path-to-clawhandoff>",
       "localRepoPath": "<path-to-local-repo-clone>",
       "defaultClaimComment": "I'm looking into this and working on a root-cause fix."
     }
   }
   ```
2. Build the `.NET` launcher and register shortcuts (`Win + R` `pr-radar`, Start Menu, optional Startup):
   ```powershell
   pwsh -NoProfile -File .\Install-Shortcuts.ps1
   ```
   *(Or launch directly: `pwsh -NoProfile -STA -File .\pr-radar-hud.ps1 -RefreshOnLaunch`)*

To remove shortcuts and `PATH` registration cleanly:

```powershell
pwsh -NoProfile -File .\Install-Shortcuts.ps1 -Uninstall
```
