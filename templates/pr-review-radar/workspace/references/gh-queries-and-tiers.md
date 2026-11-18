# Read-Only GitHub Queries & Priority Tiers

## 1. Four-Slice Read-Only Collection (Fast, Co-Author-Aware & 504-Proof)

Large repositories with 100+ CI checks per PR can time out GitHub's GraphQL API if `statusCheckRollup` and `files` are requested across 40+ PRs at once, and a single `--author` filter misses PRs published via automation bots or pair-programming teammates where `viewerHandle` is a commit co-author. Collect **four bounded read-only slices** per `owner/repo` (`slug` = `owner__repo`) and let `pr-radar-engine.mjs` merge and deduplicate them:

```bash
# 1) Directly authored PRs (P1 & P2 — includes statusCheckRollup + mergeable)
gh pr list --repo <owner/repo> --author <viewerHandle> --state open --limit 20 \
  --json number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,labels,statusCheckRollup,updatedAt,createdAt \
  > state/<slug>-authored.json

# 2) Co-authored / bot-published PRs (P1 & P2 — verified strictly via structured commits[].authors)
gh pr list --repo <owner/repo> --search "<viewerHandle> -author:<viewerHandle>" --state open --limit 20 \
  --json number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,labels,commits,statusCheckRollup,updatedAt,createdAt \
  > state/<slug>-coauthored.json

# 3) Explicit review requests (P3 — includes statusCheckRollup)
gh pr list --repo <owner/repo> --search "review-requested:<viewerHandle>" --state open --limit 20 \
  --json number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,reviewRequests,labels,statusCheckRollup,updatedAt,createdAt \
  > state/<slug>-reviews.json

# 4) Recent PRs for subsystem overlap watch (P4 — omits statusCheckRollup to avoid GraphQL 504s)
gh pr list --repo <owner/repo> --state open --limit 25 \
  --json number,title,url,isDraft,author,headRefName,headRefOid,labels,files,updatedAt,createdAt \
  > state/<slug>-recent.json

# 5) Lazy mergeability & >100-check rollup resolver (resolves transient UNKNOWN mergeable states after main advances)
node scripts/resolve-mergeability.mjs --repo <owner/repo> \
  --slice state/<slug>-authored.json \
  --slice state/<slug>-coauthored.json \
  --slice state/<slug>-reviews.json \
  --out state/<slug>-mergeability.json
```

Then merge slices into `state/latest-sweep.json` and score in one step:

```bash
node scripts/pr-radar-engine.mjs --mode score \
  --slice <owner/repo>=state/<slug>-authored.json \
  --slice <owner/repo>=state/<slug>-coauthored.json \
  --slice <owner/repo>=state/<slug>-reviews.json \
  --slice <owner/repo>=state/<slug>-recent.json \
  --slice <owner/repo>=state/<slug>-mergeability.json \
  --save-sweep --config state/config.json --cursors state/cursors.json --json
```

## 2. Deterministic Priority Tiers (Structured State Only)

| Tier | Name | Structured Inclusion Criteria | Static Operator Move |
| --- | --- | --- | --- |
| `P1` | **Unblock Yours Now** | Authored by `viewerHandle` OR co-authored (`commits[].authors` includes `viewerHandle`) AND has non-cancelled failing checks (deduplicated by latest run), `CONFLICTING` / `DIRTY` merge state, or `CHANGES_REQUESTED` review decision | Rebase conflicts, inspect named failing checks/gates, or address requested review changes |
| `P2` | **Ready to Land** | Authored or co-authored (`commits[].authors`) by `viewerHandle`, not a draft, zero conflicts, and checks passing (distinguishes immediately mergeable PRs from `BLOCKED` / `REVIEW_REQUIRED` branch-gated PRs) | Verify final diff and merge, or await/request maintainer landing |
| `P3` | **Review Queue Waiting on You** | Not authored by `viewerHandle`, not a draft, and `reviewRequests` explicitly includes `viewerHandle` | Review green, conflict-free PRs first |
| `P4` | **Subsystem Overlap Watch** | Not authored by `viewerHandle`, touches any prefix in `watchedPaths`, carries a label in `watchedLabels`, or matches `watchedKeywords` (`focusTopic`) | Skim touched files early to avoid duplicate work or rebase collisions |

## 3. Tracked PR/Issue Delta Watch & 5-Gate Candidate Vetting (`watch-and-vet-engine.mjs`)

For contributors actively tracking specific PRs/issues and scouting genuinely unclaimed candidate issues, `scripts/watch-and-vet-engine.mjs` provides two read-only workflows:

```bash
# Run read-only tracked PR/issue delta check + 5-gate candidate issue vetting
node scripts/watch-and-vet-engine.mjs --mode sweep --config state/config.json --json

# Collect all-time surface evidence (merged PRs, open PRs, open/closed issues, top contributors & paths)
node scripts/watch-and-vet-engine.mjs --mode collect-surface --topic "subagents" --config state/config.json
```

## 4. State-Fingerprint Deduplication

`scripts/pr-radar-engine.mjs` deduplicates repeated check runs by latest timestamp, ignores superseded `CANCELLED` workflow runs, and computes a SHA-256 state fingerprint over `tier`, `headRefOid`, `isDraft`, `mergeable`, `mergeStateStatus`, `reviewDecision`, `checks.state`, and `checks.failing`. Scheduled sweeps set `shouldNotify: true` only when at least one `P1`–`P4` pull request is new or changed its structured state fingerprint since `state/cursors.json` was last committed.
