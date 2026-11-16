# `@mertbasar0/pr-review-radar`

An [OpenClaw Agent Template](https://clawhub.ai/mertbasar0/templates/pr-review-radar) (plus an optional [Windows Sticky Note HUD](companion/windows-hud/README.md)) that turns noisy GitHub pull request queues, CI check statuses, mergeability states, and subsystem overlaps into a deterministic four-tier action radar.

## Four-Tier Triage Model

1. **P1 — Unblock Yours Now:** Authored or commit-co-authored (`commits[].authors`) PRs with non-cancelled failing checks (deduplicated by latest run, including `>100`-check `rollupState` safety), merge conflicts (`CONFLICTING` / `DIRTY`, resolved across GitHub's lazy 3-way merge queue via `resolve-mergeability.mjs`), or `CHANGES_REQUESTED` review decisions.
2. **P2 — Ready to Land:** Authored or commit-co-authored non-draft PRs with green checks and zero conflicts (distinguishing immediately mergeable PRs from `BLOCKED` / `REVIEW_REQUIRED` / `BEHIND` branch-gated PRs and pending `UNKNOWN` mergeability checks).
3. **P3 — Review Queue Waiting on You:** Non-draft PRs explicitly requesting your review (`reviewRequests`), ranked with CI-green candidates first.
4. **P4 — Subsystem Overlap Watch:** Active PRs touching your configured `watchedPaths` or `watchedLabels` so overlapping refactors and neighboring surface changes surface early.

## Large-Repo Performance, Co-Author Detection & Lazy Mergeability Resolution

Repositories with 100+ CI check runs per PR and fast-moving base branches hit three common GitHub CLI traps: wide `statusCheckRollup` + `files` queries trigger GraphQL `HTTP 504` timeouts, `--author` alone misses bot-published or pair-authored PRs, and `gh pr list` returns lazy `mergeable: "UNKNOWN"` right after `main` advances—hiding real merge conflicts.

`pr-review-radar` solves all three by collecting four bounded read-only `gh pr list` slices per repository (`authored`, `coauthored` verified strictly via structured `commits[].authors`, `reviews`, and check-free `recent` overlap PRs), resolving any `UNKNOWN` merge states + overall `rollupState` in one batched GraphQL pass via `resolve-mergeability.mjs`, and merging them deterministically with `pr-radar-engine.mjs`.

## Quick Start (OpenClaw Agent Template)

```bash
openclaw templates add @mertbasar0/pr-review-radar
```

Try the built-in offline demo immediately—no GitHub credentials required:

```bash
node templates/pr-review-radar/workspace/scripts/pr-radar-engine.mjs --mode demo
```

## Optional Desktop Companion (`companion/windows-hud/`)

For Windows developers who want a persistent, zero-clutter desktop radar alongside the OpenClaw agent template, [`companion/windows-hud/`](companion/windows-hud/README.md) provides a native WPF + System Tray sticky-note HUD powered by the same `pr-radar-engine.mjs` and `resolve-mergeability.mjs` scripts:

- **Instant global hotkey (`Ctrl + Alt + R`):** Toggle the radar from anywhere in 0ms.
- **Live status-dot tray icon:** Red (`P1` active blocker/conflict), green (`P2` ready to land), or cyan (idle), with full right-click tray controls.
- **System-locale i18n (`en` / `tr`):** Automatically adapts to English or Turkish Windows UI culture (with live tray language switching and Dark / Classic Sticky Yellow themes).

## Safety Model

- **Structured metadata only (prompt-injection hardened):** Tier classification and static operator next-actions derive strictly from structured GitHub fields (`statusCheckRollup`, `rollupState`, `commits[].authors`, `mergeable`, `mergeStateStatus`, `reviewDecision`, `reviewRequests`, `isDraft`, `files`, `labels`)—never from free-form PR bodies or comment threads.
- **Read-only GitHub CLI by default:** Uses read-only `gh pr list` and `gh api graphql` metadata queries only; never merges, approves, closes, labels, or comments without explicit per-action approval in chat.
- **Paused schedules by default:** Ships two opt-in weekday cron automations (`morning-pr-radar` and `eod-review-sweep`) disabled until reviewed and enabled by the operator.
- **Workspace-local deduplication:** Advances `state/cursors.json` only after writing a verified markdown report under `reports/`, returning `NO_REPLY` on quiet scheduled sweeps.

## License

MIT
