#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";

async function writeStatusAtomic(filePath, payload) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  const tmp = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  await fs.writeFile(tmp, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  await fs.rename(tmp, filePath);
}

function parseJobArg(argv) {
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--job-file" && argv[i + 1]) {
      return path.resolve(argv[i + 1]);
    }
  }
  throw new Error("Missing --job-file <path>");
}

async function updateActiveIndex(indexFile, entry) {
  if (!indexFile) return;
  let list = [];
  try {
    const raw = JSON.parse(await fs.readFile(indexFile, "utf8"));
    if (Array.isArray(raw)) list = raw;
  } catch {}
  const filtered = list.filter(
    (item) =>
      item.handoffId !== entry.handoffId &&
      item.requestId !== entry.requestId &&
      Number(item.issueNumber) !== Number(entry.issueNumber),
  );
  filtered.unshift(entry);
  await writeStatusAtomic(indexFile, filtered.slice(0, 25));
}

async function main() {
  const jobPath = parseJobArg(process.argv.slice(2));
  const job = JSON.parse(await fs.readFile(jobPath, "utf8"));
  const {
    clawhandoffEntry,
    bridgeConfig,
    targetId,
    targetLabel,
    issueNumber,
    repo,
    envelope,
    worktreeName,
    displayWorktreePath,
    statusFile,
    indexFile,
  } = job;

  const startedAt = new Date().toISOString();
  await writeStatusAtomic(statusFile, {
    ok: true,
    phase: "starting",
    issueNumber,
    repo,
    targetId,
    targetLabel,
    worktreePath: displayWorktreePath || null,
    requestId: envelope.requestId,
    startedAt,
    updatedAt: startedAt,
  });

  const modUrl = pathToFileURL(path.resolve(clawhandoffEntry)).href;
  const { BridgeService } = await import(modUrl);
  const bridge = new BridgeService(bridgeConfig);

  try {
    let result = await bridge.startHandoff({
      targetId,
      envelope,
      worktreeName: worktreeName || undefined,
      waitBudgetMs: 1_000,
      maxAutonomousTurns: 8,
    });

    const resolvedWtPath =
      displayWorktreePath ||
      (worktreeName &&
      (bridgeConfig.targets?.[targetId]?.transport === "codex" ||
        bridgeConfig.targets?.[targetId]?.transport === "acp")
        ? path.join(bridgeConfig.dataDir, "worktrees", `${result.handoffId}-${worktreeName}`)
        : null);

    const resolvePhase = (res) => {
      if (res.lifecycleStatus === "failed") return "failed";
      const act = res.orchestratorDirective?.action;
      if (act === "POLL_ATTACH" || res.lifecycleStatus === "running") return "running";
      return "settled";
    };

    const buildRecord = (res) => {
      const dir = res.orchestratorDirective;
      const notes = Array.isArray(res.observed?.verificationNotes)
        ? res.observed.verificationNotes.join("; ")
        : null;
      const phaseName = resolvePhase(res);
      return {
        ok: phaseName !== "failed",
        phase: phaseName,
        handoffId: res.handoffId,
        requestId: envelope.requestId,
        issueNumber,
        repo,
        targetId,
        targetLabel,
        lifecycleStatus: res.lifecycleStatus,
        runId: res.runId ?? null,
        remoteSessionKey: res.remoteSessionKey ?? null,
        remoteSessionUrl: res.remoteSessionUrl ?? null,
        worktreeName: worktreeName || `issue-${issueNumber}`,
        worktreePath: resolvedWtPath,
        directiveAction: dir?.action ?? null,
        directiveReason: dir?.reason ?? null,
        summary: res.reported?.summaryDelta ?? null,
        headSha: res.reported?.candidateCommitSha ?? res.observed?.observedHeadSha ?? null,
        errorMessage: phaseName === "failed" ? notes || dir?.reason || "Target run failed" : null,
        startedAt,
        updatedAt: new Date().toISOString(),
      };
    };

    const initialRec = buildRecord(result);
    await writeStatusAtomic(statusFile, initialRec);
    await updateActiveIndex(indexFile, initialRec);

    const maxRuntimeMs = 45 * 60 * 1000;
    const deadline = Date.now() + maxRuntimeMs;

    while (
      result.orchestratorDirective?.action === "POLL_ATTACH" &&
      Date.now() < deadline
    ) {
      await delay(2_000);
      result = await bridge.attachHandoff({
        handoffId: result.handoffId,
        waitBudgetMs: 25_000,
      });
      const rec = buildRecord(result);
      await writeStatusAtomic(statusFile, rec);
      await updateActiveIndex(indexFile, rec);
    }
  } catch (err) {
    const errRec = {
      ok: false,
      phase: "failed",
      issueNumber,
      repo,
      targetId,
      targetLabel,
      worktreePath: displayWorktreePath || null,
      requestId: envelope.requestId,
      errorCode: err?.code ?? "WORKER_ERROR",
      errorMessage: err instanceof Error ? err.message : String(err),
      startedAt,
      updatedAt: new Date().toISOString(),
    };
    await writeStatusAtomic(statusFile, errRec);
    await updateActiveIndex(indexFile, errRec);
    process.exitCode = 1;
  } finally {
    await bridge.close().catch(() => {});
  }
}

await main();
