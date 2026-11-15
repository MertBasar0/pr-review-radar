#!/usr/bin/env node

import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE_ROOT = path.resolve(SCRIPT_DIR, "..");

function resolveSafeWorkspacePath(candidatePath, fallbackPath) {
  const resolved = path.resolve(WORKSPACE_ROOT, candidatePath ?? fallbackPath);
  const rel = path.relative(WORKSPACE_ROOT, resolved);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new Error(`Refusing path outside agent workspace: ${candidatePath}`);
  }
  return resolved;
}

function parseArgs(argv) {
  const opts = {
    mode: "score",
    input: path.join(WORKSPACE_ROOT, "state", "latest-sweep.json"),
    config: path.join(WORKSPACE_ROOT, "state", "config.json"),
    cursors: path.join(WORKSPACE_ROOT, "state", "cursors.json"),
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

function summarizeChecks(rollup) {
  const entries = Array.isArray(rollup) ? rollup : [];
  const failing = [];
  let pending = 0;
  let passing = 0;
  for (const item of entries) {
    const name = sanitizeDisplayField(item?.name ?? item?.context ?? "check", 60) || "check";
    const status = String(item?.status ?? "").toUpperCase();
    const conclusion = String(item?.conclusion ?? item?.state ?? "").toUpperCase();
    if (
      ["FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED", "ERROR", "STARTUP_FAILURE"].includes(
        conclusion,
      )
    ) {
      failing.push(name);
    } else if (
      ["IN_PROGRESS", "QUEUED", "PENDING", "WAITING", "REQUESTED"].includes(status) ||
      conclusion === "PENDING" ||
      (!conclusion && status && status !== "COMPLETED")
    ) {
      pending += 1;
    } else if (["SUCCESS", "NEUTRAL", "SKIPPED"].includes(conclusion)) {
      passing += 1;
    }
  }
  const state =
    failing.length > 0 ? "failing" : pending > 0 ? "pending" : passing > 0 ? "passing" : "none";
  return { state, failing: failing.slice(0, 5), pending, passing, total: entries.length };
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

/**
 * Deterministic classification strictly from structured GitHub PR metadata.
 * Free-form PR bodies and comments are intentionally excluded so untrusted prose
 * can never alter priority tiers or inject operator recommendations.
 */
function classifyPullRequest(repo, pr, config) {
  const viewer = normalizeHandle(config.viewerHandle);
  const author = normalizeHandle(pr?.author?.login);
  const isMine = Boolean(viewer && author === viewer);
  const isDraft = Boolean(pr?.isDraft);
  const mergeState = String(pr?.mergeStateStatus ?? "UNKNOWN").toUpperCase();
  const reviewDecision = String(pr?.reviewDecision ?? "").toUpperCase();
  const checks = summarizeChecks(pr?.statusCheckRollup);

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
    const hasConflict = ["CONFLICTING", "DIRTY"].includes(mergeState);
    const changesRequested = reviewDecision === "CHANGES_REQUESTED";
    const checksFailing = checks.state === "failing";

    if (checksFailing || hasConflict || changesRequested) {
      tier = "P1";
      if (checksFailing) reasons.push(`failing checks (${checks.failing.length})`);
      if (hasConflict) reasons.push(`merge state: ${mergeState}`);
      if (changesRequested) reasons.push("changes requested");
      nextAction = checksFailing
        ? "Inspect failing CI checks and push a root-cause fix"
        : hasConflict
          ? "Rebase onto base branch and resolve merge conflicts"
          : "Address requested review changes";
    } else if (
      !isDraft &&
      ["CLEAN", "MERGEABLE", "HAS_HOOKS", "UNSTABLE"].includes(mergeState) &&
      (checks.state === "passing" || checks.state === "none") &&
      reviewDecision !== "REVIEW_REQUIRED"
    ) {
      tier = "P2";
      reasons.push(
        reviewDecision === "APPROVED" ? "approved & checks green" : "mergeable & checks green",
      );
      nextAction = "Verify final diff and merge or request maintainer landing";
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
    headRefOid,
    isDraft,
    tier,
    reasons,
    nextAction,
    checks,
    mergeState,
    reviewDecision: reviewDecision || null,
    updatedAt: sanitizeDisplayField(pr?.updatedAt ?? "", 40),
    fingerprint,
  };
}

function tierRank(item) {
  const order = { P1: 1, P2: 2, P3: 3, P4: 4 };
  const checkBonus = item.tier === "P3" && item.checks.state === "passing" ? 0 : 1;
  return [order[item.tier] ?? 9, item.changeState === "unchanged" ? 1 : 0, checkBonus];
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

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const isDemo = opts.mode === "demo";

  const sweep = isDemo
    ? await readJsonOrDefault(path.join(WORKSPACE_ROOT, "fixtures", "sample-pr-sweep.json"), {})
    : await readJsonOrDefault(opts.input, null);

  if (!sweep || !Array.isArray(sweep.repositories)) {
    process.stderr.write(`Invalid or missing PR sweep input: ${opts.input}\n`);
    process.exit(1);
  }

  const config = isDemo
    ? (sweep.demoConfig ?? {})
    : await readJsonOrDefault(opts.config, {
        viewerHandle: "",
        watchedPaths: [],
        watchedLabels: [],
      });
  const cursors = isDemo
    ? { version: 1, updatedAt: null, items: {} }
    : await readJsonOrDefault(opts.cursors, { version: 1, updatedAt: null, items: {} });
  const previousItems = cursors?.items && typeof cursors.items === "object" ? cursors.items : {};

  const ranked = [];
  for (const repoEntry of sweep.repositories) {
    const repo = String(repoEntry?.repo ?? "unknown/repo");
    const pulls = Array.isArray(repoEntry?.pullRequests) ? repoEntry.pullRequests : [];
    for (const pr of pulls) {
      const item = classifyPullRequest(repo, pr, config);
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

  if (opts.mode === "commit-cursor") {
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
    repositories: sweep.repositories.map((r) => sanitizeDisplayField(r?.repo, 80)),
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
