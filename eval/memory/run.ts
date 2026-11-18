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
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { BudgetExhausted, QuotaExhausted, createBudget, providerFetch } from "./budget.mjs";
import { probeScenario, runBrief } from "./probe.mjs";
import { ExtractionFailed, PROVIDER_HOSTS, replayScenario } from "./replay";
import { loadScenarios } from "./scenario.mjs";
import { snapshotDigest, takeSnapshot } from "./snapshot.mjs";
import { localStack } from "./stack.mjs";

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
if (!["extract", "probe", "all"].includes(phase)) {
  console.error("memory eval: --phase must be extract, probe or all");
  process.exit(2);
}

const stack = localStack(env);
if (!stack) {
  console.error("memory eval: needs a local stack (source eval/privacy/local-env.sh)");
  process.exit(2);
}
const geminiKey = env.GEMINI_API_KEY?.trim() ?? "";
if (phase !== "probe" && !geminiKey) {
  console.error("memory eval: extract needs GEMINI_API_KEY");
  process.exit(2);
}
if (phase !== "extract" && !env.EMBED_INTERNAL_SECRET?.trim()) {
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

// The newest saved file for a scenario across every earlier run directory, so
// a run resumes whatever commit it is on. Directory names sort by date.
function latest(kind: "graphs" | "briefs", id: string): string | null {
  if (!existsSync(resultsRoot)) return null;
  const dirs = readdirSync(resultsRoot).filter((d) => /^\d{4}-\d{2}-\d{2}-/.test(d)).sort().reverse();
  for (const dir of dirs) {
    const path = join(resultsRoot, dir, "memory", kind, `${id}.json`);
    if (existsSync(path)) return path;
  }
  return null;
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
const budget = createBudget(Math.max(0, limit - today.used));
const fetchImpl = providerFetch({ budget, providerHosts: PROVIDER_HOSTS, supabaseUrl: stack.url });
let logged = 0;
const saveQuota = () => {
  today.used += budget.used() - logged;
  logged = budget.used();
  const stop = fetchImpl.stopReason();
  if (stop && !today.stops.includes(stop.name)) today.stops.push(stop.name);
  writeJson(quotaPath, quotaLog);
};

const scenarios = loadScenarios(join(root, "eval/memory/scenarios")).filter((s) => !only || s.id === only);
const rel = (p: string) => relative(root, p);

async function extract() {
  const log: Array<Record<string, unknown>> = [];
  let done = 0;
  for (const scenario of scenarios) {
    if (latest("graphs", scenario.id)) continue;
    if (fetchImpl.stopReason()) break;
    const users: string[] = [];
    try {
      const user = await stack!.createUser(users);
      const result = await replayScenario({
        scenario,
        env: { supabaseUrl: stack!.url, anonKey: stack!.anonKey, user, geminiKey },
        fetchImpl,
        takeSnapshot: (notebookId) => takeSnapshot({ ...stack!.admin, userId: user.id, notebookId }),
      });
      const snapshot = result.snapshot as Parameters<typeof snapshotDigest>[0];
      writeJson(join(runDir, "graphs", `${scenario.id}.json`), {
        meta: { ...result.meta, commit: sha },
        digest: snapshotDigest(snapshot),
        snapshot,
      });
      log.push({ scenario: scenario.id, outcome: "saved", providerCalls: result.meta.providerCalls, actions: result.meta.actions });
      done += 1;
      console.log(`extract ${scenario.id}: saved (${result.meta.providerCalls} calls)`);
    } catch (error) {
      if (error instanceof BudgetExhausted || error instanceof QuotaExhausted) {
        log.push({ scenario: scenario.id, outcome: error.name });
        console.log(`extract ${scenario.id}: stopped (${error.name}); nothing saved for it`);
        break;
      }
      const outcome = error instanceof ExtractionFailed ? `${error.statusCode} ${error.code}` : (error as Error).message;
      log.push({ scenario: scenario.id, outcome: `failed: ${outcome}` });
      console.log(`extract ${scenario.id}: failed (${outcome}); nothing saved`);
    } finally {
      for (const id of users) await stack!.deleteUser(id);
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
    if (error instanceof BudgetExhausted || error instanceof QuotaExhausted) {
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
    const probeResults = await probeScenario({
      snapshot: saved.snapshot,
      scenario,
      stack,
      embedSecret: env.EMBED_INTERNAL_SECRET,
      brief: (ctx: { user: { id: string; token: string }; notebookId: string }) => brief(scenario.id, saved.digest, ctx),
    });
    sources[scenario.id] = { graph: rel(path), extractCommit: saved.meta.commit, actions: saved.meta.actions,
      brief: probeResults[0]?.briefOutcome ?? "not_run" };
    results.push(...probeResults);
    console.log(`probe ${scenario.id}: ${probeResults.length} probes, brief ${probeResults[0]?.briefOutcome}`);
  }
  writeJson(join(runDir, "probes.json"), { commit: sha, k: 8, sources, results });
  return { results, sources };
}

let exitCode = 0;
try {
  const swept = await stack.sweep();
  if (swept) console.log(`swept ${swept} leftover memory-eval users`);
  if (phase !== "probe") await extract();
  if (phase !== "extract") await probe();
} catch (error) {
  console.error(`memory eval failed: ${(error as Error).message}`);
  exitCode = 1;
} finally {
  saveQuota();
  await stack.sweep().catch(() => {});
}
process.exit(exitCode);
