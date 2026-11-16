#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE_ROOT = process.env.OPENCLAW_RADAR_WORKSPACE
  ? path.resolve(process.env.OPENCLAW_RADAR_WORKSPACE)
  : path.resolve(SCRIPT_DIR, "..");
const REPO_SLUG_RE = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)$/;

function resolveSafeWorkspacePath(candidatePath) {
  const resolved = path.resolve(WORKSPACE_ROOT, String(candidatePath ?? ""));
  const rel = path.relative(WORKSPACE_ROOT, resolved);
  if (!candidatePath || rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new Error(`Refusing path outside workspace: ${candidatePath}`);
  }
  return resolved;
}

function parseArgs(argv) {
  const opts = {
    repo: "",
    slices: [],
    out: "",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--repo" && argv[i + 1]) {
      opts.repo = String(argv[++i]).trim();
    } else if (arg === "--slice" && argv[i + 1]) {
      opts.slices.push(resolveSafeWorkspacePath(argv[++i]));
    } else if (arg === "--out" && argv[i + 1]) {
      opts.out = resolveSafeWorkspacePath(argv[++i]);
    }
  }
  return opts;
}

function isUnknownMergeState(pr) {
  const mergeable = String(pr?.mergeable ?? "").toUpperCase();
  const mergeState = String(pr?.mergeStateStatus ?? "").toUpperCase();
  return !mergeable || mergeable === "UNKNOWN" || !mergeState || mergeState === "UNKNOWN";
}

function fetchMergeStatesBatch(owner, name, prNumbers) {
  if (prNumbers.length === 0) return [];
  const results = [];
  const chunkSize = 30;
  for (let i = 0; i < prNumbers.length; i += chunkSize) {
    const chunk = prNumbers.slice(i, i + chunkSize);
    const selections = chunk
      .map(
        (num) =>
          `p${num}: pullRequest(number: ${num}) { number mergeable mergeStateStatus reviewDecision headCommit: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }`,
      )
      .join(" ");
    const query = `query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { ${selections} } }`;
    const raw = execFileSync(
      "gh",
      ["api", "graphql", "-f", `owner=${owner}`, "-f", `name=${name}`, "-f", `query=${query}`],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 20000 },
    );
    const parsed = JSON.parse(raw);
    const repoNode = parsed?.data?.repository ?? {};
    for (const val of Object.values(repoNode)) {
      if (val && typeof val.number === "number") {
        const rollupState =
          val?.headCommit?.nodes?.[0]?.commit?.statusCheckRollup?.state ?? null;
        results.push({
          number: val.number,
          mergeable: val.mergeable,
          mergeStateStatus: val.mergeStateStatus,
          reviewDecision: val.reviewDecision,
          rollupState,
        });
      }
    }
  }
  return results;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const match = REPO_SLUG_RE.exec(opts.repo);
  if (!match) {
    throw new Error(`Invalid or missing --repo <owner/repo>: ${opts.repo}`);
  }
  if (!opts.out) {
    throw new Error("Missing --out <state/file.json>");
  }
  const [, owner, name] = match;

  const unknownNumbers = new Set();
  for (const slicePath of opts.slices) {
    try {
      const raw = await fs.readFile(slicePath, "utf8");
      const items = JSON.parse(raw);
      for (const pr of Array.isArray(items) ? items : []) {
        const num = Number.parseInt(String(pr?.number ?? "0"), 10);
        if (num > 0 && isUnknownMergeState(pr)) {
          unknownNumbers.add(num);
        }
      }
    } catch {
      // Ignore unreadable or empty optional slice
    }
  }

  const resolvedByNumber = new Map();
  let pending = Array.from(unknownNumbers);
  const backoffScheduleMs = [0, 2200, 2000];

  for (let attempt = 0; attempt < backoffScheduleMs.length && pending.length > 0; attempt += 1) {
    if (backoffScheduleMs[attempt] > 0) {
      await delay(backoffScheduleMs[attempt]);
    }
    try {
      const fetched = fetchMergeStatesBatch(owner, name, pending);
      const nextPending = [];
      for (const item of fetched) {
        resolvedByNumber.set(item.number, item);
        if (isUnknownMergeState(item)) {
          nextPending.push(item.number);
        }
      }
      pending = nextPending;
    } catch {
      break;
    }
  }

  await fs.mkdir(path.dirname(opts.out), { recursive: true });
  await fs.writeFile(
    opts.out,
    JSON.stringify(Array.from(resolvedByNumber.values()), null, 2),
    "utf8",
  );
}

main().catch((err) => {
  process.stderr.write(`${err?.message ?? err}\n`);
  process.exitCode = 1;
});
