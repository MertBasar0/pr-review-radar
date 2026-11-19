#!/usr/bin/env node

import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

function extractOpenClawSessionTarget(bridgeConfig, targetId) {
  const target = bridgeConfig?.targets?.[targetId];
  const args = Array.isArray(target?.args) ? target.args : [];
  const idx = args.indexOf("--session");
  if (idx >= 0 && typeof args[idx + 1] === "string" && args[idx + 1].startsWith("agent:")) {
    return {
      command: target?.command || "openclaw",
      sessionKey: args[idx + 1],
    };
  }
  return null;
}

function parseHandoffResultBlock(messages) {
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const m = messages[i];
    if (m?.role !== "assistant") continue;
    const text = Array.isArray(m.content)
      ? m.content.map((c) => c?.text || "").join("\n")
      : String(m.content || m.text || "");
    const fence = /```handoff-result\s*([\s\S]*?)```/i.exec(text);
    if (fence) {
      try {
        const parsed = JSON.parse(fence[1].trim());
        return {
          summary: parsed.summaryDelta || null,
          headSha: parsed.candidateCommitSha || null,
        };
      } catch {}
    }
    if (text.trim()) {
      return {
        summary: text.trim().replace(/\s+/g, " ").slice(0, 280),
        headSha: null,
      };
    }
  }
  return { summary: null, headSha: null };
}

async function writeStatusAtomic(filePath, payload) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  const tmp = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  await fs.writeFile(tmp, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  await fs.rename(tmp, filePath);
}

function parseWorkerArgs(argv) {
  let jobPath = "";
  let attachHandoffId = "";
  let continueHandoffId = "";
  let continueMessageFile = "";
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--job-file" && argv[i + 1]) {
      jobPath = path.resolve(argv[++i]);
    } else if (argv[i] === "--attach-handoff-id" && argv[i + 1]) {
      attachHandoffId = argv[++i].trim();
    } else if (argv[i] === "--continue-handoff-id" && argv[i + 1]) {
      continueHandoffId = argv[++i].trim();
    } else if (argv[i] === "--continue-message-file" && argv[i + 1]) {
      continueMessageFile = path.resolve(argv[++i]);
    }
  }
  if (!jobPath) {
    throw new Error("Missing --job-file <path>");
  }
  return { jobPath, attachHandoffId, continueHandoffId, continueMessageFile };
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
  const {
    jobPath,
    attachHandoffId: cliAttachId,
    continueHandoffId: cliContinueId,
    continueMessageFile,
  } = parseWorkerArgs(process.argv.slice(2));
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
  const resumeHandoffId = cliAttachId || job.attachHandoffId || "";
  const contHandoffId = cliContinueId || job.continueHandoffId || "";
  const contMessage = continueMessageFile
    ? (await fs.readFile(continueMessageFile, "utf8")).trim()
    : "";

  let startedAt = new Date().toISOString();
  if (resumeHandoffId || contHandoffId) {
    try {
      const prev = JSON.parse(await fs.readFile(statusFile, "utf8"));
      if (prev?.startedAt) startedAt = prev.startedAt;
      if (contHandoffId && contMessage) {
        const runningRec = {
          ...prev,
          ok: true,
          phase: "running",
          lifecycleStatus: "running",
          directiveAction: "POLL_ATTACH",
          directiveReason: "Yeni talimat gönderiliyor...",
          updatedAt: new Date().toISOString(),
        };
        await writeStatusAtomic(statusFile, runningRec);
        await updateActiveIndex(indexFile, runningRec);
      }
    } catch {}
  } else {
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
  }

  const modUrl = pathToFileURL(path.resolve(clawhandoffEntry)).href;
  const { BridgeService } = await import(modUrl);
  const bridge = new BridgeService(bridgeConfig);

  try {
    let result =
      contHandoffId && contMessage
        ? await bridge.continueHandoff({
            handoffId: contHandoffId,
            intent: "counter_evidence_or_followup",
            message: contMessage,
            waitBudgetMs: 1_000,
          })
        : resumeHandoffId
          ? await bridge.attachHandoff({
              handoffId: resumeHandoffId,
              waitBudgetMs: 25_000,
            })
          : await bridge.startHandoff({
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
    const ocSession = extractOpenClawSessionTarget(bridgeConfig, targetId);

    if (result.lifecycleStatus !== "uncertain" || !ocSession) {
      await writeStatusAtomic(statusFile, initialRec);
      await updateActiveIndex(indexFile, initialRec);
    }

    const maxRuntimeMs = 3 * 60 * 60 * 1000;
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
      if (result.lifecycleStatus === "uncertain" && ocSession) {
        break;
      }
      const rec = buildRecord(result);
      await writeStatusAtomic(statusFile, rec);
      await updateActiveIndex(indexFile, rec);
    }

    if (result.lifecycleStatus === "uncertain" && ocSession) {
      while (Date.now() < deadline) {
        try {
          const { stdout: descOut } = await execFileAsync(
            ocSession.command,
            [
              "gateway",
              "call",
              "sessions.describe",
              "--params",
              JSON.stringify({ key: ocSession.sessionKey }),
              "--json",
            ],
            { timeout: 15_000, windowsHide: true },
          );
          const desc = JSON.parse(descOut);
          const sessStatus = desc?.session?.status;
          if (sessStatus === "running") {
            const liveRec = {
              ...initialRec,
              ok: true,
              phase: "running",
              lifecycleStatus: "running",
              directiveAction: "POLL_ATTACH",
              directiveReason: "Gateway session is actively running.",
              updatedAt: new Date().toISOString(),
            };
            await writeStatusAtomic(statusFile, liveRec);
            await updateActiveIndex(indexFile, liveRec);
            await delay(15_000);
            continue;
          }
          const { stdout: histOut } = await execFileAsync(
            ocSession.command,
            [
              "gateway",
              "call",
              "chat.history",
              "--params",
              JSON.stringify({ sessionKey: ocSession.sessionKey, limit: 4 }),
              "--json",
            ],
            { timeout: 15_000, windowsHide: true },
          ).catch(() => ({ stdout: "{}" }));
          const hist = JSON.parse(histOut || "{}");
          const extracted = parseHandoffResultBlock(hist?.messages || []);
          const failed = sessStatus === "failed" || sessStatus === "killed";
          const doneRec = {
            ...initialRec,
            ok: !failed,
            phase: failed ? "failed" : "settled",
            lifecycleStatus: failed ? "failed" : "settled",
            directiveAction: failed ? "ESCALATE_TO_HUMAN" : "CONTINUE_AUTONOMOUSLY",
            directiveReason: null,
            summary: extracted.summary,
            headSha: extracted.headSha,
            errorMessage: failed ? `Gateway session ended with status: ${sessStatus}` : null,
            updatedAt: new Date().toISOString(),
          };
          await writeStatusAtomic(statusFile, doneRec);
          await updateActiveIndex(indexFile, doneRec);
          break;
        } catch {
          await delay(15_000);
        }
      }
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
