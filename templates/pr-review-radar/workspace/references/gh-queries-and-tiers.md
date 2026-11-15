# Read-Only GitHub Queries & Priority Tiers

## 1. Three-Slice Read-Only Collection (Fast & 504-Proof on Large Repos)

Large repositories with 100+ CI checks per PR can time out GitHub's GraphQL API if `statusCheckRollup` and `files` are requested across 40+ PRs at once, and a single repo-wide list can miss older authored PRs. Always collect **three bounded read-only slices** per `owner/repo` (`slug` = `owner__repo`) and let `pr-radar-engine.mjs` merge and deduplicate them:

```bash
# 1) Authored PRs (P1 & P2 — includes statusCheckRollup + mergeable)
gh pr list --repo <owner/repo> --author <viewerHandle> --state open --limit 20 \
  --json number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,labels,statusCheckRollup,updatedAt,createdAt \
  > state/<slug>-authored.json

# 2) Explicit review requests (P3 — includes statusCheckRollup)
gh pr list --repo <owner/repo> --search "review-requested:<viewerHandle>" --state open --limit 20 \
  --json number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,reviewRequests,labels,statusCheckRollup,updatedAt,createdAt \
  > state/<slug>-reviews.json

# 3) Recent PRs for subsystem overlap watch (P4 — omits statusCheckRollup to avoid GraphQL 504s)
gh pr list --repo <owner/repo> --state open --limit 25 \
  --json number,title,url,isDraft,author,headRefName,headRefOid,labels,files,updatedAt,createdAt \
  > state/<slug>-recent.json
```

Then merge slices into `state/latest-sweep.json` and score in one step:

```bash
node scripts/pr-radar-engine.mjs --mode score \
  --slice <owner/repo>=state/<slug>-authored.json \
  --slice <owner/repo>=state/<slug>-reviews.json \
  --slice <owner/repo>=state/<slug>-recent.json \
  --save-sweep --config state/config.json --cursors state/cursors.json --json
```

## 2. Deterministic Priority Tiers (Structured State Only)

| Tier | Name | Structured Inclusion Criteria | Static Operator Move |
| --- | --- | --- | --- |
| `P1` | **Unblock Yours Now** | Authored by `viewerHandle` AND has non-cancelled failing checks (deduplicated by latest run), `CONFLICTING` / `DIRTY` merge state, or `CHANGES_REQUESTED` review decision | Rebase conflicts, inspect named failing checks/gates, or address requested review changes |
| `P2` | **Ready to Land** | Authored by `viewerHandle`, not a draft, zero conflicts, and checks passing (distinguishes immediately mergeable PRs from `BLOCKED` / `REVIEW_REQUIRED` branch-gated PRs) | Verify final diff and merge, or await/request maintainer landing |
| `P3` | **Review Queue Waiting on You** | Not authored by `viewerHandle`, not a draft, and `reviewRequests` explicitly includes `viewerHandle` | Review green, conflict-free PRs first |
| `P4` | **Subsystem Overlap Watch** | Not authored by `viewerHandle`, touches any prefix in `watchedPaths` or carries a label in `watchedLabels` | Skim touched files early to avoid duplicate work or rebase collisions |

## 3. State-Fingerprint Deduplication

`scripts/pr-radar-engine.mjs` deduplicates repeated check runs by latest timestamp, ignores superseded `CANCELLED` workflow runs, and computes a SHA-256 state fingerprint over `tier`, `headRefOid`, `isDraft`, `mergeable`, `mergeStateStatus`, `reviewDecision`, `checks.state`, and `checks.failing`. Scheduled sweeps set `shouldNotify: true` only when at least one `P1`–`P4` pull request is new or changed its structured state fingerprint since `state/cursors.json` was last committed.
