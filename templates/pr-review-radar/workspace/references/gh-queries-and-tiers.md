# Read-Only GitHub Queries & Priority Tiers

## 1. Read-Only Structured Metadata Query

Fetch open pull requests per configured repository (`owner/repo`) using `gh pr list` (read-only, structured fields only—no free-form PR bodies or comment threads):

```bash
gh pr list --repo <owner/repo> --state open --limit 40 \
  --json number,title,url,isDraft,author,headRefName,headRefOid,mergeStateStatus,reviewDecision,reviewRequests,labels,files,statusCheckRollup,updatedAt,createdAt
```

Save `{ "capturedAt": "<ISO-8601>", "repositories": [{ "repo": "<owner/repo>", "pullRequests": [...] }] }` to `state/latest-sweep.json`, then pass it to `node scripts/pr-radar-engine.mjs`.

## 2. Deterministic Priority Tiers (Structured State Only)

| Tier | Name | Structured Inclusion Criteria | Static Operator Move |
| --- | --- | --- | --- |
| `P1` | **Unblock Yours Now** | Authored by `viewerHandle` AND has failing/cancelled checks, `CONFLICTING` / `DIRTY` merge state, or `CHANGES_REQUESTED` review decision | Inspect failing CI checks, rebase conflicts, or requested review changes |
| `P2` | **Ready to Land** | Authored by `viewerHandle`, not a draft, `MERGEABLE` / `CLEAN`, checks passing, and `APPROVED` (or no blocking review decision) | Verify final diff and merge or request maintainer landing |
| `P3` | **Review Queue Waiting on You** | Not authored by `viewerHandle`, not a draft, and `reviewRequests` explicitly includes `viewerHandle` | Review green, conflict-free PRs first |
| `P4` | **Subsystem Overlap Watch** | Not authored by `viewerHandle`, touches any prefix in `watchedPaths` or carries a label in `watchedLabels` | Skim touched files early to avoid duplicate work or rebase collisions |

## 3. State-Fingerprint Deduplication

`scripts/pr-radar-engine.mjs` computes a SHA-256 state fingerprint over `tier`, `headRefOid`, `isDraft`, `mergeStateStatus`, `reviewDecision`, `checks.state`, and `checks.failing`. Scheduled sweeps set `shouldNotify: true` only when at least one `P1`–`P4` pull request is new or changed its structured state fingerprint since `state/cursors.json` was last committed.
