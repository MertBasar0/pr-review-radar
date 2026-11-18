#!/usr/bin/env node

import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE_ROOT = process.env.OPENCLAW_RADAR_WORKSPACE
  ? path.resolve(process.env.OPENCLAW_RADAR_WORKSPACE)
  : path.resolve(SCRIPT_DIR, "..");

const REPO_SLUG_RE = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)$/;
const SEEN_ISSUES_CAP = 200;

const DEFAULT_BLOCKED_LABELS = [
  "clawsweeper:no-new-fix-pr",
  "clawsweeper:needs-product-decision",
  "clawsweeper:needs-info",
  "clawsweeper:needs-security-review",
  "clawsweeper:needs-live-repro",
];

const DEFAULT_PRIORITY_LABELS = ["impact:auth-provider"];
const DEFAULT_PRIORITY_KEYWORDS = ["subagent", "subagents", "sessions_spawn", "sessions-spawn"];

const GENERIC_BASENAMES = new Set([
  "index",
  "types",
  "utils",
  "helpers",
  "config",
  "constants",
  "schema",
  "main",
  "cli",
  "mod",
  "api",
  "runtime-api",
  "package",
  "readme",
]);

const TITLE_STOPWORDS = new Set([
  "fix",
  "bug",
  "feat",
  "chore",
  "docs",
  "test",
  "when",
  "with",
  "from",
  "that",
  "this",
  "into",
  "after",
  "before",
  "while",
  "does",
  "not",
  "fail",
  "fails",
  "failed",
  "failing",
  "error",
  "issue",
  "openclaw",
  "should",
  "cannot",
  "cant",
  "missing",
  "broken",
  "wrong",
]);

function asciiSort(arr) {
  return [...arr].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

function resolveSafeWorkspacePath(candidatePath, fallbackPath) {
  const resolved = path.resolve(WORKSPACE_ROOT, candidatePath ?? fallbackPath);
  const rel = path.relative(WORKSPACE_ROOT, resolved);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new Error(`Refusing path outside agent workspace: ${candidatePath}`);
  }
  return resolved;
}

function sanitizeDisplayField(value, maxLen = 160) {
  return String(value ?? "")
    .replace(/[\u0000-\u001f\u007f`[\]<>]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLen);
}

function normalizeHandle(value) {
  return String(value ?? "")
    .trim()
    .replace(/^@/, "")
    .toLowerCase();
}

function parseArgs(argv) {
  const opts = {
    mode: "sweep",
    config: path.join(WORKSPACE_ROOT, "state", "config.json"),
    stateFile: path.join(WORKSPACE_ROOT, "state", "watch-state.json"),
    reportFile: path.join(WORKSPACE_ROOT, "state", "watch-report.json"),
    importFrom: "",
    trackSpec: "",
    untrackSpec: "",
    dismissIssue: 0,
    markClaimedIssue: 0,
    handoffId: "",
    worktreePath: "",
    topic: "",
    repoOverride: "",
    lang: "tr",
    json: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--mode" && argv[i + 1]) {
      opts.mode = argv[++i];
    } else if (arg === "--config" && argv[i + 1]) {
      opts.config = resolveSafeWorkspacePath(argv[++i], opts.config);
    } else if (arg === "--state" && argv[i + 1]) {
      opts.stateFile = resolveSafeWorkspacePath(argv[++i], opts.stateFile);
    } else if (arg === "--report" && argv[i + 1]) {
      opts.reportFile = resolveSafeWorkspacePath(argv[++i], opts.reportFile);
    } else if (arg === "--import-from" && argv[i + 1]) {
      opts.importFrom = resolveSafeWorkspacePath(argv[++i], "");
    } else if (arg === "--track" && argv[i + 1]) {
      opts.trackSpec = argv[++i];
    } else if (arg === "--untrack" && argv[i + 1]) {
      opts.untrackSpec = argv[++i];
    } else if (arg === "--dismiss-candidate" && argv[i + 1]) {
      opts.dismissIssue = Number.parseInt(argv[++i], 10) || 0;
    } else if (arg === "--mark-claimed" && argv[i + 1]) {
      opts.markClaimedIssue = Number.parseInt(argv[++i], 10) || 0;
    } else if (arg === "--handoff-id" && argv[i + 1]) {
      opts.handoffId = sanitizeDisplayField(argv[++i], 96);
    } else if (arg === "--worktree-path" && argv[i + 1]) {
      opts.worktreePath = sanitizeDisplayField(argv[++i], 260);
    } else if (arg === "--topic" && argv[i + 1]) {
      opts.topic = sanitizeDisplayField(argv[++i], 120);
    } else if (arg === "--repo" && argv[i + 1]) {
      opts.repoOverride = argv[++i].trim();
    } else if (arg === "--lang" && argv[i + 1]) {
      opts.lang = argv[++i] === "en" ? "en" : "tr";
    } else if (arg === "--json") {
      opts.json = true;
    }
  }
  return opts;
}

/**
 * Execute strictly read-only GitHub CLI commands.
 */
async function runGhJson(args, timeoutMs = 30_000) {
  const sub = args[0];
  if (!["pr", "issue", "search", "api"].includes(sub)) {
    throw new Error(`Refusing non-read-only gh subcommand: ${sub}`);
  }
  if (sub === "api") {
    for (const flag of args) {
      if (["-X", "--method", "-f", "-F", "--field", "--raw-field", "--input"].includes(flag)) {
        throw new Error(`Refusing mutating gh api flag in read-only engine: ${flag}`);
      }
    }
  } else if (!["view", "list", "prs", "issues"].includes(args[1])) {
    throw new Error(`Refusing gh ${sub} ${args[1]} in read-only engine`);
  }

  const { stdout } = await execFileAsync("gh", args, {
    timeout: timeoutMs,
    maxBuffer: 16 * 1024 * 1024,
    windowsHide: true,
  });
  const trimmed = stdout.trim();
  return trimmed ? JSON.parse(trimmed) : null;
}

/**
 * Execute strictly read-only GitHub GraphQL queries (for batched candidate & search checks
 * without hitting REST /search/issues 30-req/min rate limits). Rejects any GraphQL mutation.
 */
async function runGhGraphqlQuery(query, vars = {}, timeoutMs = 30_000) {
  if (!/^\s*query\b/i.test(query) || /\bmutation\b/i.test(query)) {
    throw new Error("Refusing non-query GraphQL document in read-only engine.");
  }
  const args = ["api", "graphql"];
  for (const [k, v] of Object.entries(vars)) {
    args.push("-f", `${k}=${v}`);
  }
  args.push("-f", `query=${query}`);
  const { stdout } = await execFileAsync("gh", args, {
    timeout: timeoutMs,
    maxBuffer: 20 * 1024 * 1024,
    windowsHide: true,
  });
  const parsed = JSON.parse(stdout);
  if (Array.isArray(parsed?.errors) && parsed.errors.length > 0 && !parsed.data) {
    throw new Error(parsed.errors[0]?.message ?? "GraphQL query error");
  }
  return parsed?.data ?? {};
}

function escapeGraphqlString(raw) {
  return String(raw ?? "")
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/[\r\n]+/g, " ")
    .trim();
}

async function readJsonOrNull(filePath) {
  try {
    return JSON.parse(await fs.readFile(filePath, "utf8"));
  } catch {
    return null;
  }
}

async function writeJsonAtomic(filePath, data) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  const tmpPath = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  await fs.writeFile(tmpPath, `${JSON.stringify(data, null, 2)}\n`, "utf8");
  await fs.rename(tmpPath, filePath);
}

function deduplicateFailingChecks(rollup, ignoredCheckNames = []) {
  const ignored = new Set(ignoredCheckNames.map((n) => sanitizeDisplayField(n, 60).toLowerCase()));
  const entries = Array.isArray(rollup) ? rollup : [];
  const latestByKey = new Map();
  entries.forEach((item, index) => {
    const wf = sanitizeDisplayField(item?.workflowName ?? "", 40);
    const rawName = sanitizeDisplayField(item?.name ?? item?.context ?? "check", 60) || "check";
    const key = `${wf.toLowerCase()}::${rawName.toLowerCase()}`;
    const ts = String(item?.completedAt ?? item?.startedAt ?? "");
    const prev = latestByKey.get(key);
    if (
      !prev ||
      (ts && (!prev.ts || ts >= prev.ts)) ||
      (!ts && !prev.ts && index >= prev.index)
    ) {
      latestByKey.set(key, { item, rawName, ts, index });
    }
  });

  const failingSet = new Set();
  for (const { item, rawName } of latestByKey.values()) {
    if (ignored.has(rawName.toLowerCase())) continue;
    const conclusion = String(item?.conclusion ?? item?.state ?? "").toUpperCase();
    if (
      ["FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"].includes(conclusion)
    ) {
      failingSet.add(rawName);
    }
  }
  return asciiSort(Array.from(failingSet));
}

function extractFirstLine(body) {
  for (const rawLine of String(body ?? "").split(/\r?\n/)) {
    const clean = sanitizeDisplayField(rawLine, 140);
    if (clean) return clean;
  }
  return "";
}

function isViewerOwnCommit(commitItem, viewerHandle, viewerAliases = []) {
  const viewer = normalizeHandle(viewerHandle);
  if (!viewer) return false;
  const aliases = new Set([
    viewer,
    ...viewerAliases.map((a) => normalizeHandle(a)).filter(Boolean),
  ]);
  const login = normalizeHandle(commitItem?.author?.login ?? "");
  const authorName = normalizeHandle(commitItem?.commit?.author?.name ?? commitItem?.authorName ?? "");
  if (aliases.has(login) || aliases.has(authorName)) {
    return true;
  }
  const msg = String(commitItem?.commit?.message ?? commitItem?.fullMessage ?? "");
  for (const line of msg.split(/\r?\n/)) {
    const m = /^co-authored-by:\s*([^<\r\n]+)/i.exec(line.trim());
    if (!m) continue;
    const coName = normalizeHandle(m[1]);
    if (aliases.has(coName)) return true;
  }
  return false;
}

async function fetchTrackedPrSnapshot(repo, number, ignoredChecks) {
  const pr = await runGhJson([
    "pr",
    "view",
    String(number),
    "--repo",
    repo,
    "--json",
    "number,title,url,state,labels,comments,mergeable,statusCheckRollup",
  ]);
  const rawCommits = await runGhJson([
    "api",
    `repos/${repo}/pulls/${number}/commits?per_page=100`,
  ]);
  const labels = asciiSort(
    (Array.isArray(pr?.labels) ? pr.labels : [])
      .map((l) => sanitizeDisplayField(l?.name ?? l, 60))
      .filter(Boolean),
  );
  const comments = Array.isArray(pr?.comments) ? pr.comments : [];
  const lastComment = comments.length > 0 ? comments[comments.length - 1] : null;
  const commitsDetailed = (Array.isArray(rawCommits) ? rawCommits : []).map((c) => {
    const fullMessage = String(c?.commit?.message ?? "");
    const headline = sanitizeDisplayField(fullMessage.split(/\r?\n/)[0] ?? "", 140);
    return {
      sha: String(c?.sha ?? "").slice(0, 8),
      author: sanitizeDisplayField(c?.commit?.author?.name ?? c?.author?.login ?? "unknown", 60),
      login: normalizeHandle(c?.author?.login ?? ""),
      headline,
      fullMessage,
      rawRef: c,
    };
  });

  return {
    snapshot: {
      kind: "pr",
      number,
      title: sanitizeDisplayField(pr?.title ?? "", 140),
      url: String(pr?.url ?? `https://github.com/${repo}/pull/${number}`),
      state: String(pr?.state ?? "OPEN").toUpperCase(),
      labels,
      commentCount: comments.length,
      lastCommentAuthor: sanitizeDisplayField(lastComment?.author?.login ?? "", 60) || null,
      mergeable: String(pr?.mergeable ?? "UNKNOWN").toUpperCase(),
      failingChecks: deduplicateFailingChecks(pr?.statusCheckRollup, ignoredChecks),
      commits: commitsDetailed.map(({ sha, author, headline }) => ({ sha, author, headline })),
    },
    comments,
    commitsDetailed,
  };
}

async function fetchTrackedIssueSnapshot(repo, number) {
  const issue = await runGhJson([
    "issue",
    "view",
    String(number),
    "--repo",
    repo,
    "--json",
    "number,title,url,state,labels,comments",
  ]);
  const labels = asciiSort(
    (Array.isArray(issue?.labels) ? issue.labels : [])
      .map((l) => sanitizeDisplayField(l?.name ?? l, 60))
      .filter(Boolean),
  );
  const comments = Array.isArray(issue?.comments) ? issue.comments : [];
  const lastComment = comments.length > 0 ? comments[comments.length - 1] : null;

  return {
    snapshot: {
      kind: "issue",
      number,
      title: sanitizeDisplayField(issue?.title ?? "", 140),
      url: String(issue?.url ?? `https://github.com/${repo}/issues/${number}`),
      state: String(issue?.state ?? "OPEN").toUpperCase(),
      labels,
      commentCount: comments.length,
      lastCommentAuthor: sanitizeDisplayField(lastComment?.author?.login ?? "", 60) || null,
    },
    comments,
    commitsDetailed: [],
  };
}

function diffTrackedEntry(prev, curr, comments, commitsDetailed, viewerHandle, viewerAliases, lang) {
  const changes = [];
  const viewer = normalizeHandle(viewerHandle);
  const tr = lang !== "en";

  if (prev.state && curr.state !== prev.state) {
    if (curr.kind === "pr") {
      if (curr.state === "MERGED") {
        changes.push(tr ? `durum MERGED oldu (birleştirildi)` : `state changed to MERGED`);
      } else if (curr.state === "CLOSED") {
        changes.push(
          tr ? `durum CLOSED oldu (merge edilmeden kapatıldı)` : `state changed to CLOSED (unmerged)`,
        );
      } else {
        changes.push(tr ? `durum ${prev.state} -> ${curr.state}` : `state ${prev.state} -> ${curr.state}`);
      }
    } else {
      changes.push(tr ? `durum ${prev.state} -> ${curr.state}` : `state ${prev.state} -> ${curr.state}`);
    }
  }

  const prevCommentCount = Number.isInteger(prev.commentCount) ? prev.commentCount : 0;
  if (curr.commentCount > prevCommentCount && comments.length > 0) {
    const newSlice = comments.slice(prevCommentCount);
    const externalComments = newSlice.filter(
      (c) => normalizeHandle(c?.author?.login) && normalizeHandle(c?.author?.login) !== viewer,
    );
    for (const ext of externalComments.slice(-2)) {
      const author = sanitizeDisplayField(ext?.author?.login ?? "unknown", 50);
      const firstLine = extractFirstLine(ext?.body ?? "");
      changes.push(
        tr
          ? `@${author} yorum yazdı: "${firstLine}"`
          : `new comment by @${author}: "${firstLine}"`,
      );
    }
  } else if (
    curr.commentCount !== prevCommentCount &&
    curr.lastCommentAuthor &&
    normalizeHandle(curr.lastCommentAuthor) !== viewer
  ) {
    const lastObj = comments[comments.length - 1];
    const firstLine = extractFirstLine(lastObj?.body ?? "");
    changes.push(
      tr
        ? `@${curr.lastCommentAuthor} yorum yazdı: "${firstLine}"`
        : `new comment by @${curr.lastCommentAuthor}: "${firstLine}"`,
    );
  }

  const prevLabels = asciiSort(Array.isArray(prev.labels) ? prev.labels : []);
  if (JSON.stringify(prevLabels) !== JSON.stringify(curr.labels)) {
    const prevSet = new Set(prevLabels);
    const added = curr.labels.filter((l) => !prevSet.has(l));
    const callouts = [];
    for (const special of [
      "status: 📣 needs proof",
      "proof: sufficient",
      "clawsweeper:no-new-fix-pr",
    ]) {
      if (added.includes(special)) {
        callouts.push(special);
      }
    }
    const prevRatings = prevLabels.filter((l) => /^(?:issue-)?rating:/i.test(l));
    const currRatings = curr.labels.filter((l) => /^(?:issue-)?rating:/i.test(l));
    if (JSON.stringify(prevRatings) !== JSON.stringify(currRatings) && currRatings.length > 0) {
      callouts.push(...currRatings);
    }
    const calloutSuffix =
      callouts.length > 0
        ? tr
          ? ` [ÖNEMLİ: ${callouts.join(", ")}]`
          : ` [NOTABLE: ${callouts.join(", ")}]`
        : "";
    changes.push(
      tr
        ? `etiketler güncellendi: [${curr.labels.join(", ")}]${calloutSuffix}`
        : `labels changed: [${curr.labels.join(", ")}]${calloutSuffix}`,
    );
  }

  if (curr.kind === "pr") {
    const prevFailing = Array.isArray(prev.failingChecks) ? prev.failingChecks : [];
    const currFailing = Array.isArray(curr.failingChecks) ? curr.failingChecks : [];
    if (prevFailing.length === 0 && currFailing.length > 0) {
      changes.push(
        tr
          ? `CI yeşilden kırmızıya döndü (${currFailing.join(", ")})`
          : `CI went from green to failing (${currFailing.join(", ")})`,
      );
    } else if (prevFailing.length > 0 && currFailing.length === 0) {
      changes.push(tr ? `CI tamamen yeşile döndü` : `CI went from failing to green`);
    }

    if (curr.mergeable === "CONFLICTING" && prev.mergeable !== "CONFLICTING") {
      changes.push(tr ? `PR CONFLICTING (çakışma) durumuna düştü` : `PR became CONFLICTING`);
    }

    const prevShas = new Set(
      (Array.isArray(prev.commits) ? prev.commits : []).map((c) => String(c?.sha ?? "")),
    );
    for (const c of commitsDetailed) {
      if (!c.sha || prevShas.has(c.sha)) continue;
      if (isViewerOwnCommit(c.rawRef, viewerHandle, viewerAliases)) continue;
      const takeoverRe = new RegExp(`\\bmerge\\b[\\s\\S]*?#?${curr.number}\\b`, "i");
      const isTakeover = takeoverRe.test(c.fullMessage);
      const takeoverNote = isTakeover
        ? tr
          ? ` [⚠️ MAINTAINER DEVRALMA/MERGE İŞARETİ]`
          : ` [⚠️ MAINTAINER MERGE/TAKEOVER SIGNAL]`
        : "";
      changes.push(
        tr
          ? `yeni dış commit (${c.sha} · ${c.author}): "${c.headline}"${takeoverNote}`
          : `new external commit (${c.sha} · ${c.author}): "${c.headline}"${takeoverNote}`,
      );
    }
  }

  return changes;
}

export function extractIssueSourcePaths(issueBody, comments) {
  const texts = [
    String(issueBody ?? ""),
    ...(Array.isArray(comments) ? comments.map((c) => String(c?.body ?? "")) : []),
  ];
  const combined = texts.join("\n");
  const found = [];
  const seen = new Set();

  const addPath = (raw) => {
    const cleaned = String(raw ?? "")
      .trim()
      .replace(/^\/+/, "")
      .replace(/#L\d+(?:-L?\d+)?$/i, "")
      .replace(/:\d+(?:-\d+)?$/, "");
    if (
      !cleaned ||
      !cleaned.includes("/") ||
      cleaned.includes("..") ||
      cleaned.startsWith("http") ||
      !/\.[A-Za-z0-9]{1,8}$/.test(cleaned)
    ) {
      return;
    }
    if (!seen.has(cleaned)) {
      seen.add(cleaned);
      found.push(cleaned);
    }
  };

  const blobRe = /blob\/[0-9a-fA-F]{7,40}\/([A-Za-z0-9_./-]+\.[A-Za-z0-9]{1,8})(?:#L\d+)?/g;
  for (const match of combined.matchAll(blobRe)) {
    addPath(match[1]);
    if (found.length >= 5) return found;
  }

  const tickRe = /`([A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\.[A-Za-z0-9]{1,8})(?::\d+(?:-\d+)?)?(?:#L\d+(?:-L?\d+)?)?`/g;
  for (const match of combined.matchAll(tickRe)) {
    addPath(match[1]);
    if (found.length >= 5) return found;
  }

  return found.slice(0, 5);
}

function extractDistinctiveTitleWords(title) {
  const words = String(title ?? "")
    .replace(/^[a-z]+(?:\([^)]+\))?:\s*/i, "")
    .split(/[^A-Za-z0-9_-]+/)
    .map((w) => w.trim())
    .filter((w) => w.length >= 4 && !TITLE_STOPWORDS.has(w.toLowerCase()));
  const unique = [];
  const seen = new Set();
  for (const w of words) {
    const low = w.toLowerCase();
    if (!seen.has(low)) {
      seen.add(low);
      unique.push(w);
    }
    if (unique.length >= 4) break;
  }
  return unique;
}

function isClawSweeperCommentAuthor(login) {
  const norm = normalizeHandle(login);
  return norm === "clawsweeper" || norm === "clawsweeper[bot]";
}

function isClawSweeperBuildingFix(comments, labels) {
  for (const label of labels) {
    if (/clawsweeper:(?:implementing|in-progress|building-fix)/i.test(label)) {
      return true;
    }
  }
  for (const comment of Array.isArray(comments) ? comments : []) {
    if (!isClawSweeperCommentAuthor(comment?.author?.login)) continue;
    const body = String(comment?.body ?? "");
    const hasProgressMarker = body.includes("clawsweeper-issue-implementation-progress");
    const hasAutoPhrase = /automatically building a fix/i.test(body);
    if (!hasProgressMarker && !hasAutoPhrase) continue;

    if (hasProgressMarker) {
      const stateMatch = /State\s*:\s*[`*_~]*\s*([A-Za-z_-]+)/i.exec(body);
      const stateWord = (stateMatch?.[1] ?? "").toLowerCase();
      if (["failed", "abandoned", "cancelled", "canceled", "error"].includes(stateWord)) {
        continue;
      }
      return true;
    }
    if (hasAutoPhrase) {
      return true;
    }
  }
  return false;
}

function detectPriorityOwnership(issue, labels, extractedPaths, priorityLabels, priorityKeywords) {
  const reasons = [];
  const lowerLabels = labels.map((l) => l.toLowerCase());
  for (const pLabel of priorityLabels) {
    if (lowerLabels.includes(pLabel.toLowerCase())) {
      reasons.push(pLabel);
    }
  }
  const haystack = [
    String(issue?.title ?? ""),
    String(issue?.body ?? "").slice(0, 3_000),
    ...labels,
    ...extractedPaths,
  ]
    .join(" ")
    .toLowerCase();
  for (const kw of priorityKeywords) {
    if (kw && haystack.includes(kw.toLowerCase())) {
      reasons.push(kw);
      break;
    }
  }
  return {
    matched: reasons.length > 0,
    reasons: Array.from(new Set(reasons)),
  };
}

/**
 * Fetch up to 40 issues in batched GraphQL queries (chunked by 20) + recent open PR files.
 */
async function fetchIssuesBatchGraphql(owner, name, issueNumbers) {
  const byNumber = new Map();
  const chunkSize = 20;
  for (let i = 0; i < issueNumbers.length; i += chunkSize) {
    const chunk = issueNumbers.slice(i, i + chunkSize);
    const fields = chunk
      .map(
        (num) =>
          `i${num}: issue(number: ${num}) { number title url state createdAt body labels(first: 30) { nodes { name } } comments(first: 40) { nodes { body author { login } } } }`,
      )
      .join(" ");
    const query = `query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { ${fields} } }`;
    const data = await runGhGraphqlQuery(query, { owner, name });
    const repoNode = data?.repository ?? {};
    for (const node of Object.values(repoNode)) {
      if (node && typeof node.number === "number") {
        byNumber.set(node.number, {
          number: node.number,
          title: node.title ?? "",
          url: node.url ?? `https://github.com/${owner}/${name}/issues/${node.number}`,
          state: node.state ?? "OPEN",
          createdAt: node.createdAt ?? "",
          body: node.body ?? "",
          labels: (node.labels?.nodes ?? []).map((l) => sanitizeDisplayField(l?.name ?? "", 70)).filter(Boolean),
          comments: node.comments?.nodes ?? [],
        });
      }
    }
  }
  return byNumber;
}

/**
 * Batched GraphQL Gate 1 check: check which issue numbers are mentioned by ANY PR in repo.
 */
async function checkDirectPrMentionsBatch(repo, issueNumbers) {
  const mentioned = new Set();
  const chunkSize = 15;
  for (let i = 0; i < issueNumbers.length; i += chunkSize) {
    const chunk = issueNumbers.slice(i, i + chunkSize);
    const searches = chunk
      .map((num) => {
        const q = escapeGraphqlString(`repo:${repo} is:pr ${num}`);
        return `q${num}: search(query: "${q}", type: ISSUE, first: 1) { issueCount }`;
      })
      .join(" ");
    const data = await runGhGraphqlQuery(`query { ${searches} }`);
    for (const num of chunk) {
      if ((data?.[`q${num}`]?.issueCount ?? 0) > 0) {
        mentioned.add(num);
      }
    }
  }
  return mentioned;
}

/**
 * Batched GraphQL Gate 4 check: search open PRs by file basename or title keywords, returning touched files directly.
 */
async function vetIssuesBatch(repo, issueNumbers, watchCfg) {
  const match = REPO_SLUG_RE.exec(repo);
  if (!match || issueNumbers.length === 0) {
    return { examined: [], cleanCandidates: [] };
  }
  const [, owner, name] = match;
  const blockedSet = new Set(
    (watchCfg.blockedLabels ?? DEFAULT_BLOCKED_LABELS).map((l) => l.toLowerCase()),
  );

  // 1) Fetch issue bodies, labels, comments in batched GraphQL
  const issuesMap = await fetchIssuesBatchGraphql(owner, name, issueNumbers);
  const examined = Array.from(issuesMap.keys());

  // 2) Filter locally via Gates 2, 3, 5 first (zero extra search queries for disqualified items!)
  const surviving = [];
  for (const num of issueNumbers) {
    const issue = issuesMap.get(num);
    if (!issue) continue;
    if (String(issue.state).toUpperCase() !== "OPEN") continue;
    if (issue.labels.some((lbl) => blockedSet.has(lbl.toLowerCase()))) continue;
    if (issue.comments.some((c) => !isClawSweeperCommentAuthor(c?.author?.login))) continue;
    if (isClawSweeperBuildingFix(issue.comments, issue.labels)) continue;
    surviving.push(issue);
  }

  if (surviving.length === 0) {
    return { examined, cleanCandidates: [] };
  }

  // 3) Gate 1: Batched direct PR number mention check
  const mentionedSet = await checkDirectPrMentionsBatch(
    repo,
    surviving.map((i) => i.number),
  );
  const afterGate1 = surviving.filter((i) => !mentionedSet.has(i.number));
  if (afterGate1.length === 0) {
    return { examined, cleanCandidates: [] };
  }

  // 4) Gate 4: Collect unique search queries across surviving issues (file basenames or title words)
  // Plus pre-fetch the 40 newest open PRs with files to catch brand-new PRs even before search indexing!
  const recentPrsData = await runGhGraphqlQuery(
    `query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(first: 40, states: OPEN, orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes { number createdAt title files(first: 100) { nodes { path } } }
        }
      }
    }`,
    { owner, name },
  );
  const prFilesByNumber = new Map();
  const recentOpenPrs = (recentPrsData?.repository?.pullRequests?.nodes ?? []).map((pr) => {
    const fileSet = new Set((pr.files?.nodes ?? []).map((f) => String(f?.path ?? "")));
    prFilesByNumber.set(pr.number, fileSet);
    return {
      number: pr.number,
      createdAt: pr.createdAt ?? "",
      title: pr.title ?? "",
    };
  });

  const searchTermsMap = new Map(); // termKey -> query string
  const issuePlans = new Map();

  for (const issue of afterGate1) {
    const extractedPaths = extractIssueSourcePaths(issue.body, issue.comments);
    if (extractedPaths.length > 0) {
      const terms = [];
      for (const fp of extractedPaths) {
        const parsed = path.posix.parse(fp);
        const baseNoExt = parsed.name;
        const parentSeg = parsed.dir.split("/").filter(Boolean).pop() ?? "";
        const term =
          GENERIC_BASENAMES.has(baseNoExt.toLowerCase()) && parentSeg
            ? `${parentSeg}/${baseNoExt}`
            : baseNoExt;
        terms.push(term);
        searchTermsMap.set(term, `repo:${repo} is:pr is:open "${escapeGraphqlString(term)}"`);
      }
      issuePlans.set(issue.number, { kind: "paths", extractedPaths, terms });
    } else {
      const words = extractDistinctiveTitleWords(issue.title);
      const termKey = `title:${issue.number}`;
      if (words.length > 0) {
        searchTermsMap.set(
          termKey,
          `repo:${repo} is:pr is:open ${escapeGraphqlString(words.join(" "))}`,
        );
      }
      issuePlans.set(issue.number, { kind: "title", extractedPaths: [], termKey, words });
    }
  }

  // Execute lightweight search terms in GraphQL batches of 10 (without nested files connection)
  const searchEntries = Array.from(searchTermsMap.entries());
  const searchResultsByKey = new Map();
  const prNumbersNeedingFiles = new Set();
  const earliestIssueCreatedAt = afterGate1
    .map((i) => String(i.createdAt ?? ""))
    .filter(Boolean)
    .sort()[0] ?? "";

  const searchChunkSize = 10;
  for (let i = 0; i < searchEntries.length; i += searchChunkSize) {
    const chunk = searchEntries.slice(i, i + searchChunkSize);
    const aliases = chunk
      .map(
        ([, q], idx) =>
          `s${idx}: search(query: "${escapeGraphqlString(q)}", type: ISSUE, first: 10) { nodes { ... on PullRequest { number createdAt title } } }`,
      )
      .join(" ");
    const data = await runGhGraphqlQuery(`query { ${aliases} }`);
    chunk.forEach(([key], idx) => {
      const nodes = (data?.[`s${idx}`]?.nodes ?? [])
        .filter((n) => n && typeof n.number === "number")
        .map((n) => ({
          number: n.number,
          createdAt: n.createdAt ?? "",
          title: n.title ?? "",
        }));
      searchResultsByKey.set(key, nodes);
      for (const n of nodes) {
        if (
          !prFilesByNumber.has(n.number) &&
          (!earliestIssueCreatedAt || !n.createdAt || n.createdAt >= earliestIssueCreatedAt)
        ) {
          prNumbersNeedingFiles.add(n.number);
        }
      }
    });
  }

  // Fetch files ONLY for candidate open PRs created after the unseen issues
  const needFilesArr = Array.from(prNumbersNeedingFiles);
  for (let i = 0; i < needFilesArr.length; i += 15) {
    const chunk = needFilesArr.slice(i, i + 15);
    const fields = chunk
      .map((num) => `p${num}: pullRequest(number: ${num}) { number files(first: 100) { nodes { path } } }`)
      .join(" ");
    const fData = await runGhGraphqlQuery(
      `query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { ${fields} } }`,
      { owner, name },
    );
    const repoNode = fData?.repository ?? {};
    for (const node of Object.values(repoNode)) {
      if (node && typeof node.number === "number") {
        prFilesByNumber.set(
          node.number,
          new Set((node.files?.nodes ?? []).map((f) => String(f?.path ?? ""))),
        );
      }
    }
  }

  const priorityLabels = watchCfg.priorityLabels ?? DEFAULT_PRIORITY_LABELS;
  const priorityKeywords = watchCfg.priorityKeywords ?? DEFAULT_PRIORITY_KEYWORDS;
  const cleanCandidates = [];

  for (const issue of afterGate1) {
    const plan = issuePlans.get(issue.number);
    const issueCreatedAt = String(issue.createdAt ?? "");
    let disqualified = false;

    if (plan.kind === "paths") {
      const candidatePrs = [...recentOpenPrs];
      for (const t of plan.terms) {
        candidatePrs.push(...(searchResultsByKey.get(t) ?? []));
      }
      for (const pr of candidatePrs) {
        if (issueCreatedAt && pr.createdAt && pr.createdAt < issueCreatedAt) continue;
        const filesSet = prFilesByNumber.get(pr.number);
        if (filesSet && plan.extractedPaths.some((fp) => filesSet.has(fp))) {
          disqualified = true;
          break;
        }
      }
    } else if (plan.words.length > 0) {
      const hits = searchResultsByKey.get(plan.termKey) ?? [];
      if (hits.some((pr) => !issueCreatedAt || !pr.createdAt || pr.createdAt >= issueCreatedAt)) {
        disqualified = true;
      }
    }

    if (disqualified) continue;

    const priority = issue.labels.find((l) => /^P[0-3]$/i.test(l))?.toUpperCase() ?? null;
    const impactLabels = issue.labels.filter((l) => /^impact:/i.test(l));
    const issueRating = issue.labels.find((l) => /^issue-rating:/i.test(l)) ?? null;
    const ownership = detectPriorityOwnership(
      issue,
      issue.labels,
      plan.extractedPaths,
      priorityLabels,
      priorityKeywords,
    );

    cleanCandidates.push({
      number: issue.number,
      repo,
      untrustedTitle: sanitizeDisplayField(issue.title, 140),
      url: issue.url,
      createdAt: issueCreatedAt,
      vettedAt: new Date().toISOString(),
      priority,
      impactLabels,
      issueRating,
      labels: asciiSort(issue.labels),
      extractedPaths: plan.extractedPaths,
      priorityFocus: ownership.matched,
      priorityReasons: ownership.reasons,
    });
  }

  return { examined, cleanCandidates };
}

async function revalidateExistingCandidatesBatch(repo, candidates, blockedLabels) {
  const match = REPO_SLUG_RE.exec(repo);
  if (!match || candidates.length === 0) return candidates;
  const [, owner, name] = match;
  try {
    const nums = candidates.map((c) => Number(c.number)).filter((n) => n > 0);
    const issuesMap = await fetchIssuesBatchGraphql(owner, name, nums);
    const mentionedSet = await checkDirectPrMentionsBatch(repo, nums);
    const blockedSet = new Set(blockedLabels.map((l) => l.toLowerCase()));

    return candidates.filter((cand) => {
      const num = Number(cand.number);
      if (mentionedSet.has(num)) return false;
      const issue = issuesMap.get(num);
      if (!issue) return true;
      if (String(issue.state).toUpperCase() !== "OPEN") return false;
      if (issue.labels.some((l) => blockedSet.has(l.toLowerCase()))) return false;
      if (issue.comments.some((c) => !isClawSweeperCommentAuthor(c?.author?.login))) return false;
      if (isClawSweeperBuildingFix(issue.comments, issue.labels)) return false;
      return true;
    });
  } catch {
    return candidates;
  }
}

function formatSweepPingText({ firstRun, deltaEvents, newCandidates, errors, lang }) {
  const tr = lang !== "en";
  if (firstRun) {
    return tr ? "İzleme başladı." : "Watch initialized.";
  }
  if (deltaEvents.length === 0 && newCandidates.length === 0 && errors.length === 0) {
    return tr ? "Değişiklik yok." : "No changes.";
  }
  const lines = [];
  for (const ev of deltaEvents) {
    const prefix = ev.kind === "pr" ? `PR #${ev.number}` : `Issue #${ev.number}`;
    lines.push(`• ${prefix} (${ev.title}): ${ev.changes.join(" | ")}`);
  }
  for (const cand of newCandidates) {
    const flag = cand.priorityFocus
      ? tr
        ? "⭐ [ÖNCELİKLİ ALAN] "
        : "⭐ [PRIORITY SURFACE] "
      : "";
    const meta = [
      cand.priority || "P?",
      ...(cand.impactLabels || []),
      cand.issueRating || "",
    ]
      .filter(Boolean)
      .join(" · ");
    lines.push(
      tr
        ? `• ${flag}Yeni temiz aday #${cand.number}: "${cand.untrustedTitle}" (${meta})`
        : `• ${flag}New clean candidate #${cand.number}: "${cand.untrustedTitle}" (${meta})`,
    );
  }
  for (const err of errors) {
    lines.push(`• ⚠️ ${err}`);
  }
  return lines.join("\n");
}

async function runCollectSurface(opts, config) {
  const repo = opts.repoOverride || config?.watch?.repo || config?.repositories?.[0] || "";
  if (!REPO_SLUG_RE.test(repo)) {
    throw new Error(`Valid owner/repo required for collect-surface, got: "${repo}"`);
  }
  const topic = opts.topic || sanitizeDisplayField(config?.focusTopic ?? "", 120);
  if (!topic) {
    throw new Error("Missing --topic <surface> for collect-surface.");
  }

  const [mergedPrsRaw, openPrsRaw, openIssuesRaw, closedIssuesRaw] = await Promise.all([
    runGhJson([
      "search",
      "prs",
      "--repo",
      repo,
      "--merged",
      topic,
      "--limit",
      "40",
      "--json",
      "number,title,author,closedAt,labels,url",
    ]).catch(() => []),
    runGhJson([
      "search",
      "prs",
      "--repo",
      repo,
      "--state",
      "open",
      topic,
      "--limit",
      "25",
      "--json",
      "number,title,author,isDraft,updatedAt,createdAt,labels,url",
    ]).catch(() => []),
    runGhJson([
      "search",
      "issues",
      "--repo",
      repo,
      "--state",
      "open",
      topic,
      "--limit",
      "30",
      "--json",
      "number,title,author,updatedAt,createdAt,commentsCount,labels,url",
    ]).catch(() => []),
    runGhJson([
      "search",
      "issues",
      "--repo",
      repo,
      "--state",
      "closed",
      topic,
      "--limit",
      "20",
      "--json",
      "number,title,author,closedAt,labels,url",
    ]).catch(() => []),
  ]);

  const mergedPrs = Array.isArray(mergedPrsRaw) ? mergedPrsRaw : [];
  const openPrs = Array.isArray(openPrsRaw) ? openPrsRaw : [];
  const openIssues = Array.isArray(openIssuesRaw) ? openIssuesRaw : [];
  const closedIssues = Array.isArray(closedIssuesRaw) ? closedIssuesRaw : [];

  const samplePrNumbers = [
    ...openPrs.slice(0, 4).map((p) => p.number),
    ...mergedPrs.slice(0, 4).map((p) => p.number),
  ].filter(Boolean);

  const pathCounts = new Map();
  const dirCounts = new Map();
  const prFilesByNumber = new Map();

  for (const num of Array.from(new Set(samplePrNumbers)).slice(0, 6)) {
    try {
      const detail = await runGhJson([
        "pr",
        "view",
        String(num),
        "--repo",
        repo,
        "--json",
        "files,headRefName,headRefOid",
      ]);
      const files = (Array.isArray(detail?.files) ? detail.files : []).map((f) =>
        String(f?.path ?? ""),
      );
      prFilesByNumber.set(num, detail);
      for (const fp of files) {
        if (!fp) continue;
        pathCounts.set(fp, (pathCounts.get(fp) ?? 0) + 1);
        const segs = fp.split("/");
        const dirPrefix =
          segs.length >= 3 ? `${segs.slice(0, 3).join("/")}/` : segs.length === 2 ? `${segs[0]}/` : fp;
        dirCounts.set(dirPrefix, (dirCounts.get(dirPrefix) ?? 0) + 1);
      }
    } catch {
      // Ignore individual PR view timeouts.
    }
  }

  const devMap = new Map();
  const bumpDev = (rawLogin, field, refNum) => {
    const handle = normalizeHandle(rawLogin);
    if (!handle || handle.endsWith("[bot]") || handle === "clawsweeper") return;
    let rec = devMap.get(handle);
    if (!rec) {
      rec = { handle, mergedPrs: 0, openPrs: 0, openIssues: 0, sampleRefs: [] };
      devMap.set(handle, rec);
    }
    rec[field] += 1;
    if (refNum && rec.sampleRefs.length < 4 && !rec.sampleRefs.includes(`#${refNum}`)) {
      rec.sampleRefs.push(`#${refNum}`);
    }
  };

  for (const pr of mergedPrs) bumpDev(pr?.author?.login, "mergedPrs", pr?.number);
  for (const pr of openPrs) bumpDev(pr?.author?.login, "openPrs", pr?.number);
  for (const iss of openIssues) bumpDev(iss?.author?.login, "openIssues", iss?.number);

  const topDevelopers = Array.from(devMap.values())
    .sort((a, b) => b.openPrs * 3 + b.mergedPrs * 2 + b.openIssues - (a.openPrs * 3 + a.mergedPrs * 2 + a.openIssues))
    .slice(0, 8);

  const labelCounts = new Map();
  for (const item of [...openPrs, ...mergedPrs, ...openIssues]) {
    for (const lbl of Array.isArray(item?.labels) ? item.labels : []) {
      const name = sanitizeDisplayField(lbl?.name ?? lbl, 60);
      if (
        !name ||
        /^size:|^status:|^rating:|^issue-rating:|^clawsweeper:|^proof:|^stale$|^no-stale$|^bug$|^enhancement$|^maintainer$|^P[0-3]$/i.test(name)
      ) {
        continue;
      }
      labelCounts.set(name, (labelCounts.get(name) ?? 0) + 1);
    }
  }

  const topDirs = Array.from(dirCounts.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5)
    .map(([d]) => d);
  const topFiles = Array.from(pathCounts.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([f, count]) => ({ path: f, count }));
  const topLabels = Array.from(labelCounts.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, 4)
    .map(([l]) => l);

  const slug = repo.replace(/\//g, "__");
  const focusSlicePath = resolveSafeWorkspacePath(`state/${slug}-focus.json`, "");
  const enrichedOpenPrs = openPrs.map((pr) => {
    const extra = prFilesByNumber.get(pr.number);
    return {
      ...pr,
      files: extra?.files ?? [],
      headRefName: extra?.headRefName ?? "",
      headRefOid: extra?.headRefOid ?? "",
    };
  });
  await writeJsonAtomic(focusSlicePath, enrichedOpenPrs);

  const evidence = {
    ok: true,
    capturedAt: new Date().toISOString(),
    repo,
    topic,
    counts: {
      mergedPrsSampled: mergedPrs.length,
      openPrs: openPrs.length,
      openIssues: openIssues.length,
      closedIssuesSampled: closedIssues.length,
    },
    inferredDirs: topDirs,
    topFiles,
    inferredLabels: topLabels,
    topDevelopers,
    openPrs: openPrs.slice(0, 15).map((p) => ({
      number: p.number,
      untrustedTitle: sanitizeDisplayField(p.title, 130),
      author: normalizeHandle(p?.author?.login),
      isDraft: Boolean(p.isDraft),
      updatedAt: p.updatedAt,
      url: p.url,
    })),
    mergedPrs: mergedPrs.slice(0, 18).map((p) => ({
      number: p.number,
      untrustedTitle: sanitizeDisplayField(p.title, 130),
      author: normalizeHandle(p?.author?.login),
      closedAt: p.closedAt,
      url: p.url,
    })),
    openIssues: openIssues.slice(0, 18).map((i) => ({
      number: i.number,
      untrustedTitle: sanitizeDisplayField(i.title, 130),
      author: normalizeHandle(i?.author?.login),
      commentsCount: i.commentsCount ?? 0,
      labels: (Array.isArray(i.labels) ? i.labels : []).map((l) =>
        sanitizeDisplayField(l?.name ?? l, 50),
      ),
      updatedAt: i.updatedAt,
      url: i.url,
    })),
    closedIssues: closedIssues.slice(0, 10).map((i) => ({
      number: i.number,
      untrustedTitle: sanitizeDisplayField(i.title, 130),
      closedAt: i.closedAt,
      url: i.url,
    })),
  };

  const evidencePath = resolveSafeWorkspacePath("state/surface-evidence.json", "");
  await writeJsonAtomic(evidencePath, evidence);
  return evidence;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const config = (await readJsonOrNull(opts.config)) ?? {};

  if (opts.mode === "collect-surface") {
    const evidence = await runCollectSurface(opts, config);
    process.stdout.write(`${JSON.stringify(evidence, null, 2)}\n`);
    return;
  }

  if (opts.mode === "import-state") {
    if (!opts.importFrom) {
      throw new Error("Expected --import-from <state/file.json>");
    }
    const ext = await readJsonOrNull(opts.importFrom);
    if (!ext || (!Array.isArray(ext.tracked) && !Array.isArray(ext.seenIssues))) {
      throw new Error(`Invalid watch state file: ${opts.importFrom}`);
    }
    const current = (await readJsonOrNull(opts.stateFile)) ?? {};
    const mergedSeen = Array.from(
      new Set([
        ...(Array.isArray(ext.seenIssues) ? ext.seenIssues : []),
        ...(Array.isArray(current.seenIssues) ? current.seenIssues : []),
      ]),
    )
      .map((n) => Number.parseInt(String(n), 10))
      .filter((n) => Number.isInteger(n) && n > 0)
      .slice(0, SEEN_ISSUES_CAP);

    const nextState = {
      version: 1,
      importedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      tracked: Array.isArray(ext.tracked) ? ext.tracked : current.tracked ?? [],
      seenIssues: mergedSeen,
      activeCandidates: Array.isArray(current.activeCandidates) ? current.activeCandidates : [],
      claimedIssues: Array.isArray(current.claimedIssues) ? current.claimedIssues : [],
    };
    await writeJsonAtomic(opts.stateFile, nextState);
    process.stdout.write(
      `${JSON.stringify({ ok: true, trackedCount: nextState.tracked.length, seenCount: nextState.seenIssues.length }, null, 2)}\n`,
    );
    return;
  }

  if (
    opts.mode === "track" ||
    opts.mode === "untrack" ||
    opts.mode === "dismiss-candidate" ||
    opts.mode === "mark-claimed"
  ) {
    const state = (await readJsonOrNull(opts.stateFile)) ?? {
      version: 1,
      updatedAt: new Date().toISOString(),
      tracked: [],
      seenIssues: [],
      activeCandidates: [],
      claimedIssues: [],
    };
    if (opts.mode === "track" && opts.trackSpec) {
      const m = /^(pr|issue):(\d+)$/i.exec(opts.trackSpec.trim());
      if (!m) throw new Error(`Expected --track pr:<number> or issue:<number>, got: ${opts.trackSpec}`);
      const kind = m[1].toLowerCase();
      const number = Number.parseInt(m[2], 10);
      if (!state.tracked.some((t) => t.kind === kind && Number(t.number) === number)) {
        state.tracked.push({ kind, number });
      }
    } else if (opts.mode === "untrack" && opts.untrackSpec) {
      const m = /^(pr|issue):(\d+)$/i.exec(opts.untrackSpec.trim());
      if (!m) throw new Error(`Expected --untrack pr:<number> or issue:<number>, got: ${opts.untrackSpec}`);
      const kind = m[1].toLowerCase();
      const number = Number.parseInt(m[2], 10);
      state.tracked = (state.tracked ?? []).filter(
        (t) => !(t.kind === kind && Number(t.number) === number),
      );
    } else if (opts.mode === "dismiss-candidate" && opts.dismissIssue > 0) {
      state.activeCandidates = (state.activeCandidates ?? []).filter(
        (c) => Number(c.number) !== opts.dismissIssue,
      );
    } else if (opts.mode === "mark-claimed" && opts.markClaimedIssue > 0) {
      const num = opts.markClaimedIssue;
      state.activeCandidates = (state.activeCandidates ?? []).filter(
        (c) => Number(c.number) !== num,
      );
      if (!state.tracked.some((t) => t.kind === "issue" && Number(t.number) === num)) {
        state.tracked.push({ kind: "issue", number: num });
      }
      const claimed = Array.isArray(state.claimedIssues) ? state.claimedIssues : [];
      claimed.unshift({
        number: num,
        handoffId: opts.handoffId || null,
        worktreePath: opts.worktreePath || null,
        claimedAt: new Date().toISOString(),
      });
      state.claimedIssues = claimed.slice(0, 30);
    }
    state.updatedAt = new Date().toISOString();
    await writeJsonAtomic(opts.stateFile, state);
    process.stdout.write(`${JSON.stringify({ ok: true, state }, null, 2)}\n`);
    return;
  }

  // Default mode: "sweep"
  const watchCfg = config.watch ?? {};
  const repo = opts.repoOverride || watchCfg.repo || config?.repositories?.[0] || "";
  if (!REPO_SLUG_RE.test(repo)) {
    const emptyReport = {
      ok: false,
      capturedAt: new Date().toISOString(),
      pingText: opts.lang === "en" ? "Watch repository not configured." : "İzleme deposu yapılandırılmadı.",
      deltaEvents: [],
      newCandidates: [],
      activeCandidates: [],
      tracked: [],
      errors: [],
    };
    process.stdout.write(`${JSON.stringify(emptyReport, null, 2)}\n`);
    return;
  }

  const viewerHandle = config.viewerHandle ?? "";
  const viewerAliases = Array.isArray(watchCfg.viewerAliases) ? watchCfg.viewerAliases : [];
  const ignoredChecks = Array.isArray(config.ignoredChecks) ? config.ignoredChecks : [];
  const existingState = await readJsonOrNull(opts.stateFile);
  const firstRun = !existingState || !Array.isArray(existingState.tracked);

  const inputTracked = firstRun
    ? Array.isArray(watchCfg.seedTracked)
      ? watchCfg.seedTracked
      : []
    : existingState.tracked;

  const nextTracked = [];
  const deltaEvents = [];
  const errors = [];

  for (const item of inputTracked) {
    const kind = item?.kind === "pr" ? "pr" : "issue";
    const number = Number.parseInt(String(item?.number ?? "0"), 10);
    if (!number || number <= 0) continue;

    try {
      const fetched =
        kind === "pr"
          ? await fetchTrackedPrSnapshot(repo, number, ignoredChecks)
          : await fetchTrackedIssueSnapshot(repo, number);
      const curr = fetched.snapshot;
      const hasPreviousSnapshot = !firstRun && typeof item.state === "string";

      if (hasPreviousSnapshot) {
        const changes = diffTrackedEntry(
          item,
          curr,
          fetched.comments,
          fetched.commitsDetailed,
          viewerHandle,
          viewerAliases,
          opts.lang,
        );
        if (changes.length > 0) {
          deltaEvents.push({
            kind,
            number,
            repo,
            title: curr.title,
            url: curr.url,
            state: curr.state,
            changes,
          });
        }
      }

      const isTerminal = curr.state === "CLOSED" || curr.state === "MERGED";
      if (!isTerminal) {
        nextTracked.push(curr);
      }
    } catch (err) {
      errors.push(
        `${kind.toUpperCase()} #${number}: gh okuma hatası (${sanitizeDisplayField(err?.message ?? String(err), 90)})`,
      );
      nextTracked.push(item);
    }
  }

  const prevSeen = Array.isArray(existingState?.seenIssues)
    ? existingState.seenIssues.map((n) => Number.parseInt(String(n), 10)).filter((n) => n > 0)
    : [];
  const seenSet = new Set(prevSeen);
  let newlyExamined = [];
  let newCandidates = [];
  const blockedLabels = watchCfg.blockedLabels ?? DEFAULT_BLOCKED_LABELS;

  const priorActive = Array.isArray(existingState?.activeCandidates)
    ? existingState.activeCandidates
    : [];
  const stillCleanPrior = await revalidateExistingCandidatesBatch(
    repo,
    priorActive.slice(0, 15),
    blockedLabels,
  );

  const candidateLabel =
    watchCfg.candidateLabel !== undefined
      ? String(watchCfg.candidateLabel)
      : "clawsweeper:queueable-fix";

  if (watchCfg.vetCandidates !== false && candidateLabel) {
    try {
      const openQueueable = await runGhJson([
        "issue",
        "list",
        "--repo",
        repo,
        "--state",
        "open",
        "--limit",
        "40",
        "--search",
        `label:"${candidateLabel}" sort:created-desc`,
        "--json",
        "number",
      ]);

      const unseenNumbers = (Array.isArray(openQueueable) ? openQueueable : [])
        .map((entry) => Number.parseInt(String(entry?.number ?? "0"), 10))
        .filter((num) => num > 0 && !seenSet.has(num));

      if (unseenNumbers.length > 0) {
        const batchRes = await vetIssuesBatch(repo, unseenNumbers, watchCfg);
        newlyExamined = batchRes.examined;
        newCandidates = batchRes.cleanCandidates;
      }
    } catch (err) {
      errors.push(
        `Aday tarama hatası: ${sanitizeDisplayField(err?.message ?? String(err), 90)}`,
      );
    }
  }

  const mergedSeenIssues = [
    ...newlyExamined,
    ...prevSeen.filter((n) => !newlyExamined.includes(n)),
  ].slice(0, SEEN_ISSUES_CAP);

  const activeByNum = new Map();
  for (const cand of [...newCandidates, ...stillCleanPrior]) {
    if (!activeByNum.has(cand.number)) {
      activeByNum.set(cand.number, cand);
    }
  }
  const activeCandidates = Array.from(activeByNum.values()).sort((a, b) => {
    if (Boolean(a.priorityFocus) !== Boolean(b.priorityFocus)) {
      return a.priorityFocus ? -1 : 1;
    }
    const pa = a.priority ?? "P9";
    const pb = b.priority ?? "P9";
    if (pa !== pb) return pa.localeCompare(pb);
    return Number(b.number) - Number(a.number);
  });

  const nextState = {
    version: 1,
    updatedAt: new Date().toISOString(),
    tracked: nextTracked,
    seenIssues: mergedSeenIssues,
    activeCandidates: activeCandidates.slice(0, 25),
    claimedIssues: Array.isArray(existingState?.claimedIssues) ? existingState.claimedIssues : [],
  };
  await writeJsonAtomic(opts.stateFile, nextState);

  const pingText = formatSweepPingText({
    firstRun,
    deltaEvents,
    newCandidates: firstRun ? [] : newCandidates,
    errors,
    lang: opts.lang,
  });

  const report = {
    ok: errors.length === 0,
    capturedAt: new Date().toISOString(),
    repo,
    firstRun,
    shouldNotify: !firstRun && (deltaEvents.length > 0 || newCandidates.length > 0),
    pingText,
    deltaEvents,
    newCandidates,
    activeCandidates: nextState.activeCandidates,
    tracked: nextTracked,
    claimedIssues: nextState.claimedIssues,
    seenCount: mergedSeenIssues.length,
    errors,
  };
  await writeJsonAtomic(opts.reportFile, report);

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }
  process.stdout.write(`${pingText}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  await main();
}
