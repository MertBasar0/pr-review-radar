# Workspace Tools & Persistence

## Local Deterministic Engine

- `node scripts/pr-radar-engine.mjs --mode demo [--json]` — Runs the built-in `fixtures/sample-pr-sweep.json` snapshot without network or `gh` authentication.
- `node scripts/pr-radar-engine.mjs --mode score --slice <owner/repo>=state/<slug>-authored.json --slice <owner/repo>=state/<slug>-coauthored.json --slice <owner/repo>=state/<slug>-reviews.json --slice <owner/repo>=state/<slug>-recent.json --save-sweep --config state/config.json --cursors state/cursors.json --json` — Merges per-repo PR slices into `state/latest-sweep.json`, verifies structured `commits[].authors` co-authorship, deduplicates repeated/cancelled check runs, classifies PRs into `P1`–`P4` strictly from structured GitHub fields, and computes `shouldNotify` against `state/cursors.json` (can also read `--input state/latest-sweep.json` directly).
- `node scripts/pr-radar-engine.mjs --mode commit-cursor --input state/latest-sweep.json --config state/config.json --cursors state/cursors.json` — Persists per-PR SHA-256 state fingerprints inside `state/cursors.json` after a briefing report is saved.

## Workspace Persistence Boundary

- Only files inside this agent workspace are read or written: `state/config.json`, `state/*-authored.json`, `state/*-coauthored.json`, `state/*-reviews.json`, `state/*-recent.json`, `state/latest-sweep.json`, `state/cursors.json`, and `reports/*.md`.

## Read-Only GitHub CLI (`gh`)

- Use only the structured read-only `gh pr list` query documented in `references/gh-queries-and-tiers.md`.
- Never run `gh pr merge`, `gh pr review`, `gh pr comment`, `gh pr close`, `gh pr edit`, or write-method `gh api` calls unless the user explicitly asks for that exact action in chat.
