#!/usr/bin/env node

import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE_ROOT = process.env.OPENCLAW_RADAR_WORKSPACE
  ? path.resolve(process.env.OPENCLAW_RADAR_WORKSPACE)
  : path.resolve(SCRIPT_DIR, "..");
const REPO_SLUG_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

function resolveSafeWorkspacePath(candidatePath, fallbackPath) {
  const resolved = path.resolve(WORKSPACE_ROOT, candidatePath ?? fallbackPath);
  const rel = path.relative(WORKSPACE_ROOT, resolved);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new Error(`Refusing path outside agent workspace: ${candidatePath}`);
  }
  return resolved;
}

function parseSliceSpec(rawSpec) {
  const eqIndex = String(rawSpec ?? "").indexOf("=");
  if (eqIndex <= 0 || eqIndex === rawSpec.length - 1) {
    throw new Error(`Expected --slice <owner/repo>=<state/file.json>, got: ${rawSpec}`);
  }
  const repo = rawSpec.slice(0, eqIndex).trim();
  if (!REPO_SLUG_RE.test(repo)) {
    throw new Error(`Invalid repository slug in --slice: ${repo}`);
  }
  const filePath = resolveSafeWorkspacePath(rawSpec.slice(eqIndex + 1).trim(), "");
  return { repo, filePath };
}

function parseArgs(argv) {
  const opts = {
    mode: "score",
    input: path.join(WORKSPACE_ROOT, "state", "latest-sweep.json"),
    config: path.join(WORKSPACE_ROOT, "state", "config.json"),
    cursors: path.join(WORKSPACE_ROOT, "state", "cursors.json"),
    slices: [],
    saveSweep: false,
    json: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--mode" && argv[i + 1]) {
      opts.mode = argv[++i];
    } else if (arg === "--input" && argv[i + 1]) {
      opts.input = resolveSafeWorkspacePath(argv[++i], opts.input);
    } else if (arg === "--config" && argv[i + 1]) {
      opts.config = resolveSafeWorkspacePath(argv[++i], opts.config);
    } else if (arg === "--cursors" && argv[i + 1]) {
      opts.cursors = resolveSafeWorkspacePath(argv[++i], opts.cursors);
    } else if (arg === "--slice" && argv[i + 1]) {
      opts.slices.push(parseSliceSpec(argv[++i]));
    } else if (arg === "--save-sweep") {
      opts.saveSweep = true;
    } else if (arg === "--json") {
      opts.json = true;
    }
  }
  return opts;
}

function normalizeHandle(value) {
  return String(value ?? "")
    .trim()
    .replace(/^@/, "")
    .toLowerCase();
}

/** Sanitize untrusted GitHub display strings to bounded single-line plain text. */
function sanitizeDisplayField(value, maxLen = 120) {
  return String(value ?? "")
    .replace(/[\u0000-\u001f\u007f`[\]<>]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLen);
}

function deduplicateCheckEntries(rollup) {
  const entries = Array.isArray(rollup) ? rollup : [];
  const latestByKey = new Map();
  entries.forEach((item, index) => {
    const wf = sanitizeDisplayField(item?.workflowName ?? "", 40);
    const rawName = sanitizeDisplayField(item?.name ?? item?.context ?? "check", 60) || "check";
    const dedupKey = `${wf.toLowerCase()}::${rawName.toLowerCase()}`;
    const timestamp = String(item?.completedAt ?? item?.startedAt ?? "");
    const existing = latestByKey.get(dedupKey);
    if (
      !existing ||
      (timestamp && (!existing.timestamp || timestamp >= existing.timestamp)) ||
      (!timestamp && !existing.timestamp && index >= existing.index)
    ) {
      latestByKey.set(dedupKey, { item, rawName, timestamp, index });
    }
  });
  return Array.from(latestByKey.values());
}

function summarizeChecks(rollup, ignoredCheckNames = [], rollupState = "") {
  const ignored = new Set(ignoredCheckNames.map((n) => sanitizeDisplayField(n, 60).toLowerCase()));
  const rawList = Array.isArray(rollup) ? rollup : [];
  const deduped = deduplicateCheckEntries(rawList);
  const failing = [];
  let pending = 0;
  let passing = 0;
  let cancelled = 0;

  for (const { item, rawName } of deduped) {
    if (ignored.has(rawName.toLowerCase())) {
      continue;
    }
    const status = String(item?.status ?? "").toUpperCase();
    const conclusion = String(item?.conclusion ?? item?.state ?? "").toUpperCase();
    if (
      ["FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"].includes(conclusion)
    ) {
      failing.push(rawName);
    } else if (
      ["IN_PROGRESS", "QUEUED", "PENDING", "WAITING", "REQUESTED"].includes(status) ||
      conclusion === "PENDING" ||
      (!conclusion && status && status !== "COMPLETED")
    ) {
      pending += 1;
    } else if (conclusion === "CANCELLED") {
      cancelled += 1;
    } else if (["SUCCESS", "NEUTRAL", "SKIPPED"].includes(conclusion)) {
      passing += 1;
    }
  }
  const overall = String(rollupState ?? "").toUpperCase();
  if (
    failing.length === 0 &&
    ignored.size === 0 &&
    rawList.length >= 100 &&
    ["FAILURE", "ERROR"].includes(overall)
  ) {
    failing.push("check beyond 100-item slice cap");
  }
  const state =
    failing.length > 0 ? "failing" : pending > 0 ? "pending" : passing > 0 ? "passing" : "none";
  return {
    state,
    failing: failing.slice(0, 5),
    failingTotal: failing.length,
    pending,
    passing,
    cancelled,
    total: deduped.length,
  };
}

function findOverlaps(pr, watchedPaths, watchedLabels) {
  const files = (Array.isArray(pr?.files) ? pr.files : []).map((f) =>
    typeof f === "string" ? f : String(f?.path ?? ""),
  );
  const labels = (Array.isArray(pr?.labels) ? pr.labels : []).map((l) =>
    (typeof l === "string" ? l : String(l?.name ?? "")).toLowerCase(),
  );
  const matchedPaths = watchedPaths
    .map((p) => sanitizeDisplayField(p, 80))
    .filter((prefix) => prefix && files.some((file) => file.startsWith(prefix)));
  const matchedLabels = watchedLabels
    .map((l) => sanitizeDisplayField(l, 40))
    .filter((label) => label && labels.includes(label.toLowerCase()));
  return { matchedPaths, matchedLabels };
}

function mergePullRequestRecord(existing, incoming) {
  if (!existing) return incoming;
  const merged = { ...existing, ...incoming };
  for (const arrayField of ["statusCheckRollup", "files", "labels", "reviewRequests", "commits"]) {
    const prevArr = Array.isArray(existing[arrayField]) ? existing[arrayField] : [];
    const nextArr = Array.isArray(incoming[arrayField]) ? incoming[arrayField] : [];
    merged[arrayField] = nextArr.length >= prevArr.length ? nextArr : prevArr;
  }
  if (
    (!incoming.mergeable || incoming.mergeable === "UNKNOWN") &&
    existing.mergeable &&
    existing.mergeable !== "UNKNOWN"
  ) {
    merged.mergeable = existing.mergeable;
  }
  if (
    (!incoming.mergeStateStatus || incoming.mergeStateStatus === "UNKNOWN") &&
    existing.mergeStateStatus &&
    existing.mergeStateStatus !== "UNKNOWN"
  ) {
    merged.mergeStateStatus = existing.mergeStateStatus;
  }
  if (!incoming.reviewDecision && existing.reviewDecision) {
    merged.reviewDecision = existing.reviewDecision;
  }
  if (!incoming.rollupState && existing.rollupState) {
    merged.rollupState = existing.rollupState;
  }
  return merged;
}

function hasCommitCoAuthor(commits, normalizedViewer) {
  if (!normalizedViewer || !Array.isArray(commits)) return false;
  for (const commit of commits) {
    for (const author of Array.isArray(commit?.authors) ? commit.authors : []) {
      if (normalizeHandle(author?.login) === normalizedViewer) {
        return true;
      }
    }
  }
  return false;
}

function normalizeRepositories(rawRepositories) {
  const byRepo = new Map();
  for (const entry of Array.isArray(rawRepositories) ? rawRepositories : []) {
    const repo = sanitizeDisplayField(entry?.repo ?? "", 80);
    if (!REPO_SLUG_RE.test(repo)) continue;
    let prMap = byRepo.get(repo);
    if (!prMap) {
      prMap = new Map();
      byRepo.set(repo, prMap);
    }
    for (const pr of Array.isArray(entry?.pullRequests) ? entry.pullRequests : []) {
      const num = Number.parseInt(String(pr?.number ?? "0"), 10);
      if (!num || num <= 0) continue;
      prMap.set(num, mergePullRequestRecord(prMap.get(num), pr));
    }
  }
  return Array.from(byRepo.entries()).map(([repo, prMap]) => ({
    repo,
    pullRequests: Array.from(prMap.values()),
  }));
}

/**
 * Deterministic classification strictly from structured GitHub PR metadata.
 * Free-form PR bodies and comments are intentionally excluded so untrusted prose
 * can never alter priority tiers or inject operator recommendations.
 */
function classifyPullRequest(repo, pr, config) {
  const viewer = normalizeHandle(config.viewerHandle);
  const author = normalizeHandle(pr?.author?.login);
  const isAuthored = Boolean(viewer && author === viewer);
  const isCoAuthored = Boolean(!isAuthored && hasCommitCoAuthor(pr?.commits, viewer));
  const isMine = isAuthored || isCoAuthored;
  const ownership = isAuthored ? "authored" : isCoAuthored ? "coauthored" : "external";
  const isDraft = Boolean(pr?.isDraft);
  const mergeable = String(pr?.mergeable ?? "").toUpperCase();
  const mergeState = String(pr?.mergeStateStatus ?? "UNKNOWN").toUpperCase();
  const reviewDecision = String(pr?.reviewDecision ?? "").toUpperCase();
  const ignoredChecks = Array.isArray(config.ignoredChecks) ? config.ignoredChecks : [];
  const checks = summarizeChecks(pr?.statusCheckRollup, ignoredChecks, pr?.rollupState);

  const requestedReviewers = (Array.isArray(pr?.reviewRequests) ? pr.reviewRequests : []).map((r) =>
    normalizeHandle(r?.login ?? r?.name ?? r?.slug),
  );
  const reviewRequested = Boolean(viewer && requestedReviewers.includes(viewer));

  const watchedPaths = Array.isArray(config.watchedPaths) ? config.watchedPaths : [];
  const watchedLabels = Array.isArray(config.watchedLabels) ? config.watchedLabels : [];
  const overlaps = findOverlaps(pr, watchedPaths, watchedLabels);

  let tier = null;
  const reasons = [];
  let nextAction = "";

  if (isMine) {
    const hasConflict =
      mergeable === "CONFLICTING" || ["CONFLICTING", "DIRTY"].includes(mergeState);
    const changesRequested = reviewDecision === "CHANGES_REQUESTED";
    const checksFailing = checks.state === "failing";

    if (checksFailing || hasConflict || changesRequested) {
      tier = "P1";
      if (isCoAuthored && author) reasons.push(`co-authored via @${author}`);
      if (isDraft) reasons.push("draft");
      if (checksFailing) {
        const preview = checks.failing.slice(0, 3).join(", ");
        reasons.push(`failing checks (${checks.failingTotal}: ${preview})`);
      }
      if (hasConflict) {
        reasons.push(
          mergeState !== "UNKNOWN" ? `merge state: ${mergeState}` : "merge conflict",
        );
      }
      if (changesRequested) reasons.push("changes requested");
      nextAction = hasConflict
        ? "Rebase onto base branch and resolve merge conflicts"
        : checksFailing
          ? "Inspect failing checks or required merge gates and push a root-cause fix"
          : "Address requested review changes";
    } else if (!isDraft && (checks.state === "passing" || checks.state === "none")) {
      tier = "P2";
      if (isCoAuthored && author) reasons.push(`co-authored via @${author}`);
      const awaitingGate =
        mergeState === "BLOCKED" ||
        mergeState === "BEHIND" ||
        reviewDecision === "REVIEW_REQUIRED";
      const mergeabilityUnknown =
        mergeable === "UNKNOWN" || (!mergeable && mergeState === "UNKNOWN");
      if (mergeabilityUnknown) {
        reasons.push("checks green; mergeability check pending");
        nextAction =
          "Refresh in a few seconds to verify merge conflicts after GitHub finishes computing mergeability";
      } else if (reviewDecision === "APPROVED" && !awaitingGate) {
        reasons.push("approved & checks green");
        nextAction = "Verify final diff and merge or request maintainer landing";
      } else if (awaitingGate) {
        reasons.push(
          mergeState === "BEHIND"
            ? "checks green; branch behind base"
            : "checks green; awaiting review or branch gate",
        );
        nextAction =
          mergeState === "BEHIND"
            ? "Update or rebase branch onto base branch, then land"
            : "Checks are green; await or request maintainer review / merge gate";
      } else {
        reasons.push("mergeable & checks green");
        nextAction = "Verify final diff and merge or request maintainer landing";
      }
    }
  } else if (!isDraft && reviewRequested) {
    tier = "P3";
    reasons.push("explicit review request");
    reasons.push(`checks: ${checks.state}`);
    nextAction =
      checks.state === "passing"
        ? "Review diff (CI checks are green)"
        : "Wait for author to resolve pending or failing checks before deep review";
  } else if (overlaps.matchedPaths.length > 0 || overlaps.matchedLabels.length > 0) {
    tier = "P4";
    if (overlaps.matchedPaths.length > 0) {
      reasons.push(`touches watched path (${overlaps.matchedPaths.join(", ")})`);
    }
    if (overlaps.matchedLabels.length > 0) {
      reasons.push(`matches watched label (${overlaps.matchedLabels.join(", ")})`);
    }
    nextAction = "Skim touched files early to avoid duplicate work or rebase collisions";
  }

  if (!tier) {
    return null;
  }

  const number = Number.parseInt(String(pr?.number ?? "0"), 10) || 0;
  const safeRepo = sanitizeDisplayField(repo, 80) || "unknown/repo";
  const key = `${safeRepo}#${number}`;
  const headRefOid = sanitizeDisplayField(pr?.headRefOid ?? "", 64);
  const fingerprint = createHash("sha256")
    .update(
      JSON.stringify({
        tier,
        headRefOid,
        isDraft,
        mergeable,
        mergeState,
        reviewDecision,
        checkState: checks.state,
        failingChecks: checks.failing,
      }),
    )
    .digest("hex");

  return {
    key,
    repo: safeRepo,
    number,
    untrustedTitle: sanitizeDisplayField(pr?.title ?? "", 120),
    url: /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/\d+$/.test(
      String(pr?.url ?? ""),
    )
      ? String(pr.url)
      : "",
    author: normalizeHandle(pr?.author?.login) || "unknown",
    ownership,
    headRefOid,
    isDraft,
    tier,
    reasons,
    nextAction,
    checks,
    mergeable: mergeable || null,
    mergeState,
    reviewDecision: reviewDecision || null,
    updatedAt: sanitizeDisplayField(pr?.updatedAt ?? "", 40),
    fingerprint,
  };
}

function tierRank(item) {
  const order = { P1: 1, P2: 2, P3: 3, P4: 4 };
  const draftPenalty = item.tier === "P1" && item.isDraft ? 1 : 0;
  const checkBonus = item.tier === "P3" && item.checks.state === "passing" ? 0 : 1;
  return [
    order[item.tier] ?? 9,
    item.changeState === "unchanged" ? 1 : 0,
    draftPenalty,
    checkBonus,
  ];
}

function compareRanked(a, b) {
  const ra = tierRank(a);
  const rb = tierRank(b);
  for (let i = 0; i < ra.length; i += 1) {
    if (ra[i] !== rb[i]) return ra[i] - rb[i];
  }
  return String(b.updatedAt).localeCompare(String(a.updatedAt));
}

async function readJsonOrDefault(filePath, fallback) {
  try {
    return JSON.parse(await fs.readFile(filePath, "utf8"));
  } catch {
    return fallback;
  }
}

async function loadSweepData(opts, isDemo) {
  if (isDemo) {
    return readJsonOrDefault(path.join(WORKSPACE_ROOT, "fixtures", "sample-pr-sweep.json"), {});
  }
  if (opts.slices.length > 0) {
    const rawRepos = [];
    for (const slice of opts.slices) {
      const parsed = await readJsonOrDefault(slice.filePath, null);
      if (!Array.isArray(parsed)) {
        throw new Error(`Expected JSON array of pull requests in slice file: ${slice.filePath}`);
      }
      rawRepos.push({ repo: slice.repo, pullRequests: parsed });
    }
    const mergedSweep = {
      capturedAt: new Date().toISOString(),
      repositories: normalizeRepositories(rawRepos),
    };
    if (opts.saveSweep) {
      await fs.mkdir(path.dirname(opts.input), { recursive: true });
      await fs.writeFile(opts.input, `${JSON.stringify(mergedSweep, null, 2)}\n`, "utf8");
    }
    return mergedSweep;
  }
  return readJsonOrDefault(opts.input, null);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const isDemo = opts.mode === "demo";

  const sweep = await loadSweepData(opts, isDemo);
  if (!sweep || !Array.isArray(sweep.repositories)) {
    process.stderr.write(`Invalid or missing PR sweep input: ${opts.input}\n`);
    process.exit(1);
  }

  const normalizedRepos = normalizeRepositories(sweep.repositories);
  const config = isDemo
    ? (sweep.demoConfig ?? {})
    : await readJsonOrDefault(opts.config, {
        viewerHandle: "",
        watchedPaths: [],
        watchedLabels: [],
        ignoredChecks: [],
      });
  const cursors = isDemo
    ? { version: 1, updatedAt: null, items: {} }
    : await readJsonOrDefault(opts.cursors, { version: 1, updatedAt: null, items: {} });
  const previousItems = cursors?.items && typeof cursors.items === "object" ? cursors.items : {};

  const ranked = [];
  for (const repoEntry of normalizedRepos) {
    for (const pr of repoEntry.pullRequests) {
      const item = classifyPullRequest(repoEntry.repo, pr, config);
      if (!item) continue;
      const prev = previousItems[item.key];
      item.changeState = !prev
        ? "new"
        : prev.fingerprint !== item.fingerprint
          ? "changed"
          : "unchanged";
      ranked.push(item);
    }
  }

  ranked.sort(compareRanked);

  if (opts.mode === "commit-cursor" && normalizedRepos.length > 0) {
    const nextItems = {};
    for (const item of ranked) {
      nextItems[item.key] = {
        tier: item.tier,
        fingerprint: item.fingerprint,
        headRefOid: item.headRefOid || undefined,
        committedAt: new Date().toISOString(),
      };
    }
    const nextCursors = {
      version: 1,
      updatedAt: new Date().toISOString(),
      items: nextItems,
    };
    await fs.mkdir(path.dirname(opts.cursors), { recursive: true });
    await fs.writeFile(opts.cursors, `${JSON.stringify(nextCursors, null, 2)}\n`, "utf8");
  }

  const tiers = {
    P1: ranked.filter((item) => item.tier === "P1"),
    P2: ranked.filter((item) => item.tier === "P2"),
    P3: ranked.filter((item) => item.tier === "P3"),
    P4: ranked.filter((item) => item.tier === "P4"),
  };
  const changedCount = ranked.filter((item) => item.changeState !== "unchanged").length;
  const output = {
    ok: true,
    mode: opts.mode,
    viewerHandle: normalizeHandle(config.viewerHandle),
    repositories: normalizedRepos.map((r) => r.repo),
    totalRanked: ranked.length,
    changedCount,
    shouldNotify: changedCount > 0,
    tiers,
  };

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
    return;
  }

  process.stdout.write(
    `PR Review Radar (@${output.viewerHandle || "unconfigured"}) — ${output.totalRanked} actionable (${output.changedCount} new/changed)\n`,
  );
  for (const [tierKey, list] of Object.entries(tiers)) {
    if (list.length === 0) continue;
    process.stdout.write(`\n[${tierKey}]\n`);
    for (const item of list) {
      process.stdout.write(
        `- [${item.changeState.toUpperCase()}] ${item.key} "${item.untrustedTitle}" (${item.reasons.join("; ")}) -> ${item.nextAction}\n`,
      );
    }
  }
}

await main();
