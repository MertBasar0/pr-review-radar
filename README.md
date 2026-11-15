# `@mertbasar0/pr-review-radar`

An [OpenClaw Agent Template](https://clawhub.ai/mertbasar0/templates/pr-review-radar) that turns noisy GitHub pull request queues, CI check statuses, and explicit review assignments into a deterministic four-tier action radar.

## Four-Tier Triage Model

1. **P1 — Unblock Yours Now:** Authored PRs with failing checks, merge conflicts, or `CHANGES_REQUESTED` review decisions.
2. **P2 — Ready to Land:** Authored non-draft PRs with green checks, clean merge state, and satisfied reviews.
3. **P3 — Review Queue Waiting on You:** Non-draft PRs explicitly requesting your review (`reviewRequests`), ranked with CI-green candidates first.
4. **P4 — Subsystem Overlap Watch:** Active PRs touching your configured `watchedPaths` or `watchedLabels` so overlapping refactors surface early.

## Quick Start

```bash
openclaw templates add @mertbasar0/pr-review-radar
```

Try the built-in offline demo immediately after adding—no GitHub credentials required:

```bash
node templates/pr-review-radar/workspace/scripts/pr-radar-engine.mjs --mode demo
```

## Safety Model

- **Structured metadata only (prompt-injection hardened):** Tier classification and static operator next-actions derive strictly from structured GitHub fields (`statusCheckRollup`, `mergeStateStatus`, `reviewDecision`, `reviewRequests`, `isDraft`, `files`, `labels`)—never from free-form PR bodies or comment threads.
- **Read-only GitHub CLI by default:** Uses `gh pr list` read-only metadata queries only; never merges, approves, closes, labels, or comments without explicit per-action approval in chat.
- **Paused schedules by default:** Ships two opt-in weekday cron automations (`morning-pr-radar` and `eod-review-sweep`) disabled until reviewed and enabled by the operator.
- **Workspace-local deduplication:** Advances `state/cursors.json` only after writing a verified markdown report under `reports/`, returning `NO_REPLY` on quiet scheduled sweeps.

## License

MIT
