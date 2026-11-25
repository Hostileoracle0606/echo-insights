/**
 * Memory-quality runner: `npm run eval:memory -- [--phase extract|probe|all] [--only <scenario>]`.
 * Local Supabase only. See eval/memory/README.md.
 *
 * extract  spends Gemini quota: replays each scenario that has no snapshot yet,
 *          stops cleanly at the day's budget or the first 429, resumes next run.
 * probe    free except one brief per scenario (cached by snapshot digest):
 *          restores every snapshot, probes retrieval and the brief, scores.
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { BudgetExhausted, ProviderAccountError, QuotaExhausted, createBudget, providerFetch } from "./budget.mjs";
import { probeScenario, runBrief } from "./probe.mjs";
import { newestRunFile } from "./results.mjs";
import { ExtractionFailed, PROVIDER_HOSTS, replayScenario } from "./replay";
import { interleaveByCategory, loadScenarios } from "./scenario.mjs";
import { scoreProbe, summarize } from "./score.mjs";
import { snapshotDigest, takeSnapshot } from "./snapshot.mjs";
import { assertPlanAuth, createPlanRunner } from "../lib/claude-plan.mjs";
import {
  BRIEF_SCHEMA, JUDGE_MODEL, PROBE_SCHEMA, RUBRIC_VERSION, applyVerdict, ask, briefInput, cacheKey,
  normalizeProbeVerdict, probeInput,
} from "./judge.mjs";
import { CALIBRATION, disagreements } from "./judge-calibration.mjs";
import { localStack, withUser } from "./stack.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const resultsRoot = join(root, "eval/results");
const env = process.env;
const args = process.argv.slice(2);
const flag = (name: string) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const phase = flag("--phase") ?? "all";
const only = flag("--only");
if (!["extract", "probe", "all", "judge"].includes(phase)) {
  console.error("memory eval: --phase must be extract, probe, all or judge");
  process.exit(2);
}
// judge: re-scores the newest saved probes.json with Claude as the only judge
// of stale facts, status, order and ambiguity. Runs on the owner's Claude plan
// through Claude Code headless (eval/lib/claude-plan.mjs), never the API and
// never Gemini; verdicts are cached by input hash.

const stack = localStack(env);
if (!stack) {
  console.error("memory eval: needs a local stack (source eval/privacy/local-env.sh)");
  process.exit(2);
}
const geminiKey = env.GEMINI_API_KEY?.trim() ?? "";
if ((phase === "extract" || phase === "all") && !geminiKey) {
  console.error("memory eval: extract needs GEMINI_API_KEY");
  process.exit(2);
}
if ((phase === "probe" || phase === "all") && !env.EMBED_INTERNAL_SECRET?.trim()) {
  console.error("memory eval: probe needs EMBED_INTERNAL_SECRET (and functions served)");
  process.exit(2);
}

const sha = execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: root }).toString().trim();
const runDir = join(resultsRoot, `${new Date().toISOString().slice(0, 10)}-${sha}`, "memory");
const writeJson = (path: string, value: unknown) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
};
const readJson = (path: string) => JSON.parse(readFileSync(path, "utf8"));

// The newest saved file for a scenario across every run directory, so a run
// resumes whatever commit it is on (results.mjs: by day, then write time).
// MEMORY_SINCE=YYYY-MM-DD ignores graphs and briefs saved by earlier runs, so
// a rerun on new code extracts everything again; older results stay on disk
// as the "before".
const since = env.MEMORY_SINCE?.trim() ?? "";
function latest(kind: "graphs" | "briefs", id: string): string | null {
  return newestRunFile(resultsRoot, `${kind}/${id}.json`,
    (path: string) => !since || relative(resultsRoot, path).slice(0, 10) >= since);
}

// Free tier: 20 requests/day/model, reset at midnight Pacific. Spend is logged
// per Pacific day so separate runs on one day share one budget.
const limit = Number(env.MEMORY_CALL_BUDGET ?? 18);
const quotaPath = join(resultsRoot, "memory-quota-log.json");
const day = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles" }).format(new Date());
const quotaLog: Record<string, { used: number; limit: number; stops: string[] }> = existsSync(quotaPath)
  ? readJson(quotaPath)
  : {};
const today = (quotaLog[day] ??= { used: 0, limit, stops: [] });
today.limit = limit;
// After a 429, no more provider calls that day, briefs included: never retry past one.
// MEMORY_RESUME_AFTER_429=1 is the owner's explicit say-so to try again the
// same day; the first new 429 still stops the run.
const stoppedToday = today.stops.includes("QuotaExhausted") && env.MEMORY_RESUME_AFTER_429 !== "1";
const budget = createBudget(stoppedToday ? 0 : Math.max(0, limit - today.used));
// Free-tier per-minute limits: one provider call per MEMORY_CALL_INTERVAL_MS.
const fetchImpl = providerFetch({
  budget, providerHosts: PROVIDER_HOSTS, supabaseUrl: stack.url,
  minIntervalMs: Number(env.MEMORY_CALL_INTERVAL_MS ?? 7000),
});
let logged = 0;
const saveQuota = () => {
  today.used += budget.used() - logged;
  logged = budget.used();
  const stop = fetchImpl.stopReason();
  if (stop && !today.stops.includes(stop.name)) today.stops.push(stop.name);
  writeJson(quotaPath, quotaLog);
};

const scenarios = interleaveByCategory(loadScenarios(join(root, "eval/memory/scenarios")))
  .filter((s) => !only || s.id === only);
const rel = (p: string) => relative(root, p);
// Test users whose delete failed even after retries; the final sweep retries them.
const leftovers: string[] = [];

async function extract() {
  const log: Array<Record<string, unknown>> = [];
  let done = 0;
  for (const scenario of scenarios) {
    if (latest("graphs", scenario.id)) continue;
    if (fetchImpl.stopReason()) break;
    try {
      const { value: result, leftover } = await withUser(stack!, (user: { id: string; token: string }) => replayScenario({
        scenario,
        env: { supabaseUrl: stack!.url, anonKey: stack!.anonKey, user, geminiKey },
        fetchImpl,
        takeSnapshot: (notebookId) => takeSnapshot({ ...stack!.admin, userId: user.id, notebookId }),
      }));
      leftovers.push(...leftover);
      const snapshot = result.snapshot as Parameters<typeof snapshotDigest>[0];
      writeJson(join(runDir, "graphs", `${scenario.id}.json`), {
        meta: { ...result.meta, commit: sha },
        digest: snapshotDigest(snapshot),
        snapshot,
      });
      log.push({ scenario: scenario.id, outcome: "saved", providerCalls: result.meta.providerCalls, actions: result.meta.actions, lostTurns: result.meta.lostTurns });
      done += 1;
      console.log(`extract ${scenario.id}: saved (${result.meta.providerCalls} calls)`);
    } catch (error) {
      if (error instanceof BudgetExhausted || error instanceof QuotaExhausted || error instanceof ProviderAccountError) {
        log.push({ scenario: scenario.id, outcome: error.name });
        console.log(`extract ${scenario.id}: stopped (${error.name}); nothing saved for it`);
        break;
      }
      const outcome = error instanceof ExtractionFailed ? `${error.statusCode} ${error.code}` : (error as Error).message;
      log.push({ scenario: scenario.id, outcome: `failed: ${outcome}` });
      console.log(`extract ${scenario.id}: failed (${outcome}); nothing saved`);
    } finally {
      saveQuota();
    }
  }
  const left = scenarios.filter((s) => !latest("graphs", s.id)).length;
  if (log.length) writeJson(join(runDir, "extract-log.json"), log);
  console.log(`extract: ${done} saved this run; provider calls today ${today.used}/${limit}`);
  if (left) console.log(`resume tomorrow: ${left} scenarios left`);
}

async function brief(scenarioId: string, digest: string, { user, notebookId }: { user: { id: string; token: string }; notebookId: string }) {
  const cached = latest("briefs", scenarioId);
  if (cached) {
    const saved = readJson(cached);
    if (saved.digest === digest && saved.outcome === "ready") return saved;
  }
  if (!geminiKey) return { brief: null, outcome: "not_run: no GEMINI_API_KEY" };
  if (fetchImpl.stopReason()) return { brief: null, outcome: `not_run: ${fetchImpl.stopReason()!.name}` };
  try {
    const result = await runBrief({ stack, user, notebookId, geminiKey, fetchImpl });
    const saved = { digest, ...result };
    writeJson(join(runDir, "briefs", `${scenarioId}.json`), saved);
    return saved;
  } catch (error) {
    if (error instanceof BudgetExhausted || error instanceof QuotaExhausted || error instanceof ProviderAccountError) {
      return { brief: null, outcome: `not_run: ${error.name}` };
    }
    throw error;
  } finally {
    saveQuota();
  }
}

async function probe() {
  const results: unknown[] = [];
  const sources: Record<string, unknown> = {};
  for (const scenario of scenarios) {
    const path = latest("graphs", scenario.id);
    if (!path) {
      sources[scenario.id] = { graph: null };
      continue;
    }
    const saved = readJson(path);
    if (snapshotDigest(saved.snapshot) !== saved.digest) throw new Error(`${rel(path)}: digest mismatch`);
    const { results: probeResults, leftover } = await probeScenario({
      snapshot: saved.snapshot,
      scenario,
      stack,
      embedSecret: env.EMBED_INTERNAL_SECRET,
      brief: (ctx: { user: { id: string; token: string }; notebookId: string }) => brief(scenario.id, saved.digest, ctx),
    });
    leftovers.push(...leftover);
    sources[scenario.id] = { graph: rel(path), extractCommit: saved.meta.commit, actions: saved.meta.actions,
      lostTurns: saved.meta.lostTurns ?? [], brief: probeResults[0]?.briefOutcome ?? "not_run" };
    results.push(...probeResults);
    console.log(`probe ${scenario.id}: ${probeResults.length} probes, brief ${probeResults[0]?.briefOutcome}`);
  }
  writeJson(join(runDir, "probes.json"), { commit: sha, k: 8, sources, results });
  return { results, sources };
}

// The newest extract-log entry for a scenario, across run directories.
function lastExtractOutcome(id: string): string | undefined {
  const entries = (path: string) => (readJson(path) as Array<{ scenario: string; outcome: string }>).filter((e) => e.scenario === id);
  const newest = newestRunFile(resultsRoot, "extract-log.json", (path: string) => entries(path).length > 0);
  return newest ? entries(newest).pop()?.outcome : undefined;
}

type ProbeResult = { scenario: string; probeIndex: number; retrieved: Array<{ name: string }>; briefOutcome: string };

const actionsAppliedFor = (sources: Record<string, any>, id: string) => sources[id]?.actions?.length
  ? sources[id].actions.every((a: { outcome: string }) => a.outcome === "applied")
  : undefined;

type Judged = {
  probes: Map<string, Record<string, string>>;
  briefs: Map<string, boolean>;
  meta: Record<string, unknown>;
};

// Claude as the only judge of stale/status/order/ambiguity (judge.mjs).
// Calibration runs first; verdicts are cached by input hash across runs.
async function judge({ results, sources }: { results: any[]; sources: Record<string, any> }): Promise<Judged> {
  await assertPlanAuth();
  const client = createPlanRunner();
  const cachePath = newestRunFile(resultsRoot, "judgments.json");
  const cache: Record<string, any> = cachePath ? readJson(cachePath).cache ?? {} : {};
  const used: Record<string, any> = {};
  let calls = 0;
  const usage = { input_tokens: 0, output_tokens: 0 };
  const models = new Set<string>();
  const cached = async (kind: string, text: string, schema: object) => {
    const key = cacheKey(kind, text);
    if (!cache[key]) {
      const { verdict, model, usage: u } = await ask(client, text, schema);
      calls += 1;
      usage.input_tokens += u?.input_tokens ?? 0;
      usage.output_tokens += u?.output_tokens ?? 0;
      cache[key] = { verdict, model };
    }
    models.add(cache[key].model);
    used[key] = cache[key];
    return cache[key].verdict;
  };
  const byId = new Map(scenarios.map((s) => [s.id, s]));

  const calibration = [];
  for (const c of CALIBRATION) {
    const scenario = byId.get(c.scenario)!;
    let verdict;
    if (c.kind === "brief") {
      verdict = await cached("brief", briefInput(scenario, c.brief), BRIEF_SCHEMA);
    } else {
      const probe = scenario.probes[c.probeIndex];
      const { text, checks } = probeInput(scenario, probe, { retrieved: c.retrieved }, c.rule);
      verdict = normalizeProbeVerdict(await cached("probe", text, PROBE_SCHEMA), checks);
    }
    const off = disagreements(c.expect, verdict);
    calibration.push({ id: c.id, agreed: off.length === 0, disagreements: off, reason: verdict.reason ?? verdict.stale_reason });
  }
  const calibrated = calibration.every((c) => c.agreed);
  console.log(`judge calibration: ${calibration.filter((c) => c.agreed).length}/${calibration.length} agree${calibrated ? "" : " — judge marked uncalibrated"}`);

  const briefs = new Map<string, boolean>();
  const briefVerdicts: Record<string, unknown> = {};
  for (const r of results) {
    if (briefs.has(r.scenario) || !r.brief?.text) continue;
    const verdict = await cached("brief", briefInput(byId.get(r.scenario)!, r.brief.text), BRIEF_SCHEMA);
    briefs.set(r.scenario, verdict.stale === "stale");
    briefVerdicts[r.scenario] = verdict;
  }
  const probes = new Map<string, Record<string, string>>();
  for (const r of results) {
    const scenario = byId.get(r.scenario)!;
    const probe = scenario.probes[r.probeIndex];
    const rule = scoreProbe(probe, r, { actionsApplied: actionsAppliedFor(sources, r.scenario) });
    const { text, checks } = probeInput(scenario, probe, r, rule);
    probes.set(`${r.scenario}:${r.probeIndex}`, normalizeProbeVerdict(await cached("probe", text, PROBE_SCHEMA), checks));
  }
  writeJson(join(runDir, "judgments.json"), {
    model: JUDGE_MODEL, rubricVersion: RUBRIC_VERSION, calibration,
    briefs: briefVerdicts,
    probes: Object.fromEntries(probes),
    cache: used,
  });
  console.log(`judge: ${calls} new Claude calls (${usage.input_tokens} in / ${usage.output_tokens} out tokens), ${Object.keys(used).length - calls} cached`);
  return {
    probes, briefs,
    meta: { model: JUDGE_MODEL, servedBy: [...models], rubricVersion: RUBRIC_VERSION, calibrated,
      calibration: `${calibration.filter((c) => c.agreed).length}/${calibration.length}`, newCalls: calls, usage },
  };
}

function score({ results, sources }: { results: unknown[]; sources: Record<string, any> }, judged?: Judged) {
  const byId = new Map(scenarios.map((s) => [s.id, s]));
  let ruleAgreement = { stale: [0, 0], status: [0, 0], order: [0, 0], ambiguity: [0, 0] };
  const rows = (results as ProbeResult[]).map((r) => {
    const scenario = byId.get(r.scenario)!;
    const probe = scenario.probes[r.probeIndex];
    const row = {
      scenario: r.scenario,
      category: scenario.category,
      probeIndex: r.probeIndex,
      ask: probe.ask,
      retrievedNames: r.retrieved.map((i) => i.name),
      brief: r.briefOutcome,
      ...scoreProbe(probe, r, { actionsApplied: actionsAppliedFor(sources, r.scenario) }),
    };
    if (!judged) return row;
    const verdict = judged.probes.get(`${r.scenario}:${r.probeIndex}`)!;
    const out = applyVerdict(row, verdict, judged.briefs.get(r.scenario));
    // How often the old string rules would have agreed: reported, never scored.
    const pairs: Array<[keyof typeof ruleAgreement, unknown, unknown]> = [
      ["stale", row.stale === null ? null : row.staleIn.some((p: string) => p !== "brief"), out.stale === null ? null : verdict.stale === "stale"],
      ["status", row.status, out.status], ["order", row.order, out.order], ["ambiguity", row.ambiguity, out.ambiguity],
    ];
    for (const [k, a, b] of pairs) {
      if (a === null || a === "n/a") continue;
      ruleAgreement[k][1] += 1;
      if (a === b) ruleAgreement[k][0] += 1;
    }
    return { ...out, judge: verdict };
  });
  const missing = scenarios.filter((s) => !sources[s.id]?.graph);
  const memory = {
    version: 1,
    target: "local",
    commit: sha,
    scoredAt: new Date().toISOString(),
    method: {
      extractionRunsPerScenario: 1,
      model: "gemini-2.5-flash (thinking off), extraction Lambda in-process",
      retrieval: "retrieve-memory, scope notebook, k=8, local gte-small embeddings; every probe notebook also holds the same 50 synthetic unrelated background entities (eval/memory/fixtures/background.json), so ranking is among distractors",
      insertions: "unrelated insertion = a retrieved background entity; other scenario entities are counted as sameStory; probe `related` names are left out of precision",
      staleNegation: "a stale term counts only where asserted: not after not/never/instead of/rather than/no longer, nor in a sentence saying misspoke/corrected/correction",
      pathAttribution: "combined: retrieve-memory returns one ranked list and does not say which path found an item",
      statusRule: "decided is correct when a retrieved entity description or active relation contains a decided marker and none contains a tentative marker; Lumen stores no tentative/decided field, so this scores the stored text",
      limitation: "N=1 extraction per scenario: no run-to-run spread is claimed",
      ...(judged ? {
        judge: {
          ...judged.meta,
          scope: "stale (retrieval and brief), status, order and ambiguity are Claude's verdicts only; recall, rank and precision stay deterministic",
          rubric: "eval/memory/judge.mjs SYSTEM_PROMPT; calibration cases in eval/memory/judge-calibration.mjs",
          ruleAgreement: Object.fromEntries(Object.entries(ruleAgreement).map(([k, [a, n]]) => [k, `${a}/${n}`])),
        },
      } : {}),
    },
    scenarios: {
      total: scenarios.length,
      scored: scenarios.length - missing.length,
      probesScored: rows.length,
      probesTotal: scenarios.reduce((n, s) => n + s.probes.length, 0),
      // Not scored yet: no snapshot. `failed` = the latest extract attempt
      // ended in an error (not a quota stop); `pending` = not attempted or
      // stopped by quota.
      failed: missing.filter((s) => lastExtractOutcome(s.id)?.startsWith("failed")).map((s) => ({ id: s.id, outcome: lastExtractOutcome(s.id) })),
      pending: missing.filter((s) => !lastExtractOutcome(s.id)?.startsWith("failed")).map((s) => s.id),
      lostTurns: Object.fromEntries(Object.entries(sources).filter(([, v]) => v.lostTurns?.length).map(([id, v]) => [id, v.lostTurns])),
      briefs: Object.fromEntries(Object.entries(sources).map(([id, v]) => [id, v.brief ?? "not_run"])),
      actions: Object.fromEntries(Object.entries(sources).filter(([, v]) => v.actions?.length).map(([id, v]) => [id, v.actions])),
    },
    summary: summarize(rows),
    probes: rows,
  };
  writeJson(join(runDir, "memory.json"), memory);
  const t = memory.summary.total;
  console.log(`scored ${rows.length}/${memory.scenarios.probesTotal} probes from ${memory.scenarios.scored}/${scenarios.length} scenarios`);
  console.log(`first expected rank: 1st ${t.firstRank.at1} · 2nd–3rd ${t.firstRank.at2to3} · later ${t.firstRank.later} · not retrieved ${t.firstRank.none} · precision@3 ${t.precisionAt3.hit}/${t.precisionAt3.of} · background insertions ${t.inserted.items} in ${t.inserted.probes} probes · same-story items ${t.sameStory}`);
  console.log(`recall@1 ${t.recallAt1.hit}/${t.recallAt1.of} · recall@3 ${t.recallAt3.hit}/${t.recallAt3.of} · recall@8 ${t.recall.hit}/${t.recall.of} (k covered the whole graph in ${t.coversGraph.probes}/${t.coversGraph.of} probes) · extraction misses ${t.extractionMisses.count}/${t.extractionMisses.ofExpected} · precision@8 ${t.precision.hit}/${t.precision.of}`);
  console.log(`stale probes ${t.stale.probes}/${t.stale.of} (retrieval ${t.stale.retrieval}/${t.stale.of}; vacuous ${t.staleVacuous}) · stale briefs ${t.briefs.stale}/${t.briefs.of} · status ${t.status.correct}/${t.status.of} · order ${t.order.kept}/${t.order.of} · ambiguity ${t.ambiguity.acknowledged}/${t.ambiguity.of} · distractor confusion ${t.distractors.confused}/${t.distractors.of}`);
}

let exitCode = 0;
try {
  const swept = await stack.sweep();
  if (swept) console.log(`swept ${swept} leftover memory-eval users`);
  if (phase === "extract" || phase === "all") await extract();
  if (phase === "probe" || phase === "all") score(await probe());
  if (phase === "judge") {
    const saved = newestRunFile(resultsRoot, "probes.json");
    if (!saved) throw new Error("no probes.json yet: run --phase probe first");
    const data = readJson(saved);
    console.log(`judging ${rel(saved)}`);
    score(data, await judge(data));
  }
} catch (error) {
  console.error(`memory eval failed: ${(error as Error).message}`);
  exitCode = 1;
} finally {
  saveQuota();
  try {
    const swept = await stack.sweep();
    if (leftovers.length || swept) console.log(`cleanup: ${leftovers.length} delete(s) failed during the run; final sweep removed ${swept} memory-eval user(s)`);
  } catch (error) {
    console.error(`cleanup: final sweep failed (${(error as Error).message}); memory-eval users may remain, the next run's sweep removes them`);
    exitCode = exitCode || 1;
  }
}
process.exit(exitCode);
