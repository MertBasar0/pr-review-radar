# `@mertbasar0/pr-review-radar`

An [OpenClaw Agent Template](https://clawhub.ai/mertbasar0/templates/pr-review-radar) (plus an optional [Windows Sticky Note HUD](companion/windows-hud/README.md)) that turns noisy GitHub pull request queues, CI check statuses, mergeability states, surface history, and unclaimed candidate issues into a compact, deterministic action radar.

## Capabilities

1. **Four-Tier PR Action Radar (`pr-radar-engine.mjs` + `resolve-mergeability.mjs`):**
   - **P1 — Unblock Yours Now:** Authored or commit-co-authored (`commits[].authors`) PRs with non-cancelled failing checks (deduplicated by latest run, including `>100`-check `rollupState` safety), merge conflicts (`CONFLICTING` / `DIRTY`, resolved across GitHub's lazy 3-way merge queue), or `CHANGES_REQUESTED` review decisions.
   - **P2 — Ready to Land:** Authored or commit-co-authored non-draft PRs with green checks and zero conflicts (distinguishing immediately mergeable PRs from `BLOCKED` / `REVIEW_REQUIRED` / `BEHIND` branch-gated PRs).
   - **P3 — Review Queue Waiting on You:** Non-draft PRs explicitly requesting your review (`reviewRequests`), ranked with CI-green candidates first.
   - **P4 — Focused Surface & Overlap Watch:** Active PRs touching your focused `watchedPaths`, `watchedLabels`, or `watchedKeywords` (`focusTopic`) so neighboring work surfaces before rebase collisions happen.
2. **In-HUD Agent-Driven Surface Focus & Collapsible All-Time Brief (`surface-focus-runner.mjs`):**
   - Type any subsystem or topic directly into the Sticky HUD focus bar (e.g., `sessions_spawn`, `blobster`, `auth-provider`) to dispatch your local AI agent (`openclaw`, `codex`, `gemini`, `claude`, or `ollama`).
   - Scans **all-time** merged PRs, open PRs, open/closed issues, and local Git path/author history to automatically update radar focus rules and synthesize a **collapsible 1-click brief** covering current surface state, concrete unclaimed contribution opportunities, and the most active maintainers/contributors.
3. **Tracked PR/Issue Delta Watch & 5-Gate Candidate Vetting (`watch-and-vet-engine.mjs`):**
   - Tracks selected PRs and issues for state transitions (`MERGED`/`CLOSED`, auto-dropping after one report), external comments, notable label updates, CI regressions, `CONFLICTING` status, and external/maintainer takeover commits—emitting an exact quiet marker (`Değişiklik yok.` / `No changes.`) when nothing changed.
   - Vets unseen `clawsweeper:queueable-fix` issues across **all 5 strict gates** via batched read-only GraphQL queries (zero direct PR mentions, zero non-bot comments, zero disqualifying triage labels, zero open PRs touching cited source files, and no active ClawSweeper auto-implementation), prominently highlighting configured priority ownership surfaces.
4. **End-to-End Stage-1 Claim & Stage-2 PR Continuation (`handoff-launcher.mjs` + `handoff-session-worker.mjs`):**
   - **Stage 1 (Claim & Isolated Worktree Launch):** Auto-detects local Windows/WSL coding agents (`openclaw`, `codex`, `gemini`, `claude`) and `@mertbasar0/clawhandoff` targets, previews the editable GitHub ownership claim comment inline, runs a live race-condition check + per-issue launch lock, creates an isolated detached Git worktree, launches the agent session, posts the approved claim comment, and enrolls the issue into live tracking.
   - **Stage 2 (Verify, Continue & Publish PR):** Live-reconciles running sessions (`⏳ RUNNING` -> `✓ STAGE 1 READY · <shortSha>`) directly on the main HUD. From any settled session card, operators can send follow-up instructions (`💬 Continue`) into the same session or click **`🚀 Verify & Open PR`** to inspect production-vs-test LOC deltas, preview/opt-in to a redacted `Agent Transcript`, rebase cleanly onto `upstream/main`, push to their fork, open a Draft -> Mergeable -> Ready PR, and auto-enroll the new PR into `P1`/`P2` tracking.

## Quick Start (OpenClaw Agent Template)

```bash
openclaw templates add @mertbasar0/pr-review-radar
```

Try the built-in offline demo immediately—no GitHub credentials required:

```bash
node templates/pr-review-radar/workspace/scripts/pr-radar-engine.mjs --mode demo
```

## Optional Desktop Companion (`companion/windows-hud/`)

See [`companion/windows-hud/README.md`](companion/windows-hud/README.md) for setup, global hotkey (`Ctrl + Alt + R`), collapsible Surface Focus Brief, Candidate Vetting, and `clawhandoff` integration.

## Safety Model

- **Structured metadata & untrusted-data isolation:** Tier classification and candidate vetting rely strictly on structured GitHub fields; all PR/issue titles, bodies, and comments are sanitized and framed as untrusted evidence.
- **Read-only background sweeps:** Background sweeps execute strictly read-only `gh` / GraphQL `query` operations. Issue ownership comments are posted **only** when explicitly confirmed by the operator in the HUD preview box, after verifying no rival claim or PR arrived.
- **Paused schedules by default:** Bundled template cron automations ship with `enabled: false` and `delivery.mode: "none"`.

## License

MIT
