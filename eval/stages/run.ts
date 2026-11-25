/**
 * Stage-isolated memory evaluation:
 *   npm run eval:stages -- [--track extraction|admission|oracle|e2e|all] [--split test|val] [--only <world>] [--smoke]
 *
 * Local Supabase only. Gemini (the system under test) is capped by
 * STAGES_GEMINI_CALL_BUDGET (calls). Claude (data judge) runs on the owner's
 * plan via Claude Code headless, never the API. Per-world results are saved as
 * they finish, so a stopped run resumes; the summary is rebuilt from them.
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { PlanLimitReached, assertPlanAuth, createPlanRunner } from "../lib/claude-plan.mjs";
import { BudgetExhausted, ProviderAccountError, QuotaExhausted, createBudget, providerFetch } from "../memory/budget.mjs";
import { PROVIDER_HOSTS } from "../memory/replay";
import { localStack } from "../memory/stack.mjs";
import { percentile, prf } from "./metrics.mjs";
import { attributionShares, renderReport } from "./report.mjs";
import { bootstrap, pairedBootstrap } from "./stats.mjs";
import { runE2EWorld } from "./tracks/e2e";
import { goldSnapshot, rankWorld } from "./tracks/oracle.mjs";
import { replayWorld } from "./tracks/replay";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const env = process.env;
const args = process.argv.slice(2);
const flag = (n: string) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined; };
const track = flag("--track") ?? "all";
const split = flag("--split") ?? "test";
const smoke = args.includes("--smoke");
const only = flag("--only");
const want = (t: string) => track === "all" || track === t;
const needsReplay = want("extraction") || want("admission") || want("e2e");

const stack = localStack(env);
if (!stack) { console.error("stages: needs a local stack (source eval/privacy/local-env.sh)"); process.exit(2); }
const geminiKey = env.GEMINI_API_KEY?.trim() ?? "";
if (needsReplay && !geminiKey) { console.error("stages: extraction/admission/e2e need GEMINI_API_KEY"); process.exit(2); }
if ((want("oracle") || want("e2e")) && !env.EMBED_INTERNAL_SECRET?.trim()) { console.error("stages: oracle/e2e need EMBED_INTERNAL_SECRET (functions served)"); process.exit(2); }

const dataDir = join(root, "eval/stages/data", smoke ? "smoke" : "", split);
const records = readFileSync(join(dataDir, "worlds.jsonl"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l))
  .filter((r) => !only || r.world.id === only);
const manifest = JSON.parse(readFileSync(join(dataDir, "manifest.json"), "utf8"));
const kept = new Set(records.flatMap((r) => r.written.queries.map((q: { id: string }) => q.id)).filter((id) => !(manifest.removedDuplicateQueries ?? []).includes(id)));
for (const r of records) r.world.queries = r.world.queries.filter((q: { id: string }) => kept.has(q.id));

const sha = execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: root }).toString().trim();
const runDir = join(root, "eval/results", `${new Date().toISOString().slice(0, 10)}-${sha}`, "stages", smoke ? "smoke" : split);
mkdirSync(join(runDir, "worlds"), { recursive: true });
const writeJson = (p: string, v: unknown) => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, `${JSON.stringify(v, null, 2)}\n`); };

const cachePath = join(root, "eval/results/stages-claude-cache.json");
const cacheData: Record<string, unknown> = existsSync(cachePath) ? JSON.parse(readFileSync(cachePath, "utf8")) : {};
const cache = { get: (k: string) => cacheData[k], set: (k: string, v: unknown) => { cacheData[k] = v; writeFileSync(cachePath, `${JSON.stringify(cacheData)}\n`); } };

const budget = createBudget(Number(env.STAGES_GEMINI_CALL_BUDGET ?? 1500));
const fetchImpl = providerFetch({ budget, providerHosts: PROVIDER_HOSTS, supabaseUrl: stack.url, minIntervalMs: Number(env.STAGES_CALL_INTERVAL_MS ?? 0) });
await assertPlanAuth();
const runner = createPlanRunner();

let stopped: string | null = null;
const leftovers: string[] = [];
try {
  if (await stack.sweep()) console.log("swept leftover eval users");
  for (const record of records) {
    const out = join(runDir, "worlds", `${record.world.id}.json`);
    if (existsSync(out)) continue;
    const result: Record<string, unknown> = { worldId: record.world.id };
    if (needsReplay) {
      const replay = await replayWorld({ record, stack, geminiKey, fetchImpl, runner, cache });
      leftovers.push(...(replay.leftover ?? []));
      const { snapshot, leftover, ...rest } = replay;
      result.replay = rest;
      if (want("e2e")) {
        const e2e = await runE2EWorld({ record, replay, stack, embedSecret: env.EMBED_INTERNAL_SECRET, geminiKey, fetchImpl, runner, cache });
        leftovers.push(...(e2e.leftover ?? []));
        result.e2e = e2e.rows;
      }
    }
    if (want("oracle")) {
      const snapshot = goldSnapshot(record.world);
      result.oracle = [];
      for (const mode of ["hybrid", "lexical"]) {
        const ranked = await rankWorld({ world: record.world, written: record.written, snapshot, stack, embedSecret: env.EMBED_INTERNAL_SECRET, mode });
        leftovers.push(...(ranked.leftover ?? []));
        (result.oracle as unknown[]).push(...ranked.value);
      }
    }
    writeJson(out, result);
    console.log(`stages ${record.world.id}: done`);
  }
} catch (error) {
  if (error instanceof BudgetExhausted || error instanceof QuotaExhausted || error instanceof ProviderAccountError || error instanceof PlanLimitReached) {
    stopped = `${(error as Error).name}: ${(error as Error).message}`;
    console.log(`stages: stopped (${stopped}); finished worlds are kept, rerun to resume`);
  } else throw error;
} finally {
  try { await stack.sweep(); } catch { /* next run's sweep retries */ }
}

// ---- aggregate everything saved for this run ----
const worlds = readdirSync(join(runDir, "worlds")).map((f) => JSON.parse(readFileSync(join(runDir, "worlds", f), "utf8")));
const byWorld = (x: { worldId: string }) => x.worldId;
const metrics: Record<string, unknown> = {};
const boot = (name: string, items: any[], metric: (xs: any[]) => number | null) => {
  if (items.length) metrics[name] = bootstrap({ items, groupKey: byWorld, metric, resamples: 2000, seed: 1 });
};
const sum = (xs: any[], f: (x: any) => number) => xs.reduce((n, x) => n + f(x), 0);
const mean = (xs: any[], f: (x: any) => number | null) => { const v = xs.map(f).filter((x) => x != null) as number[]; return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null; };

const ex = worlds.filter((w) => w.replay).map((w) => ({ worldId: w.worldId, ...w.replay.extraction }));
boot("Extraction · entity precision", ex, (xs) => prf(sum(xs, (x) => x.entities.tp), sum(xs, (x) => x.entities.fp), sum(xs, (x) => x.entities.fn)).precision);
boot("Extraction · entity recall", ex, (xs) => prf(sum(xs, (x) => x.entities.tp), sum(xs, (x) => x.entities.fp), sum(xs, (x) => x.entities.fn)).recall);
boot("Extraction · entity F1", ex, (xs) => prf(sum(xs, (x) => x.entities.tp), sum(xs, (x) => x.entities.fp), sum(xs, (x) => x.entities.fn)).f1);
boot("Extraction · relation F1 (entity pairs)", ex, (xs) => prf(sum(xs, (x) => x.pairs.tp), sum(xs, (x) => x.pairs.fp), sum(xs, (x) => x.pairs.fn)).f1);
boot("Extraction · relation F1 (typed, Claude-judged labels)", ex, (xs) => prf(sum(xs, (x) => x.typed.tp), sum(xs, (x) => x.typed.fp), sum(xs, (x) => x.typed.fn)).f1);
boot("Extraction · attribute recall", ex, (xs) => { const of = sum(xs, (x) => x.attributes.of); return of ? sum(xs, (x) => x.attributes.hit) / of : null; });

const adm = worlds.filter((w) => w.replay).flatMap((w) => w.replay.admission.map((a: any) => ({ worldId: w.worldId, ...a })));
const share = (xs: any[], ok: (x: any) => boolean) => (xs.length ? xs.filter(ok).length / xs.length : null);
boot("Admission · valid memory persistence rate", adm, (xs) => share(xs, (x) => x.outcome === "persisted" || x.outcome === "merged_correct"));
boot("Admission · false rejection rate", adm, (xs) => share(xs, (x) => x.outcome === "rejected"));
boot("Admission · wrong merge rate", adm, (xs) => share(xs, (x) => x.outcome === "merged_wrong"));

const oracle = worlds.flatMap((w) => w.oracle ?? []).filter((r: any) => r.metrics);
for (const mode of ["hybrid", "lexical"]) {
  const rows = oracle.filter((r: any) => r.mode === mode);
  const tag = mode === "hybrid" ? "hybrid, production" : "lexical-only fallback";
  for (const [key, label] of [["recallAt1", "Recall@1"], ["recallAt5", "Recall@5"], ["recallAt10", "Recall@10"], ["mrr", "MRR"], ["ndcg10", "NDCG@10"]]) {
    boot(`Oracle retrieval (${tag}) · ${label}`, rows, (xs) => mean(xs, (x) => x.metrics[key]));
  }
}
const paired = oracle.filter((r: any) => r.mode === "hybrid").map((h: any) => ({ worldId: h.worldId, h, l: oracle.find((x: any) => x.mode === "lexical" && x.queryId === h.queryId) })).filter((p: any) => p.l);
if (paired.length) {
  metrics["Oracle · hybrid − lexical, Recall@10 (paired)"] = (({ diff, ...r }) => ({ value: diff, ...r }))(pairedBootstrap({ items: paired, groupKey: byWorld, a: (xs) => mean(xs, (x) => x.h.metrics.recallAt10) ?? 0, b: (xs) => mean(xs, (x) => x.l.metrics.recallAt10) ?? 0 }));
  metrics["Oracle · hybrid − lexical, MRR (paired)"] = (({ diff, ...r }) => ({ value: diff, ...r }))(pairedBootstrap({ items: paired, groupKey: byWorld, a: (xs) => mean(xs, (x) => x.h.metrics.mrr) ?? 0, b: (xs) => mean(xs, (x) => x.l.metrics.mrr) ?? 0 }));
}

const e2e = worlds.flatMap((w) => w.e2e ?? []);
boot("End to end · answer accuracy (all questions)", e2e, (xs) => share(xs, (x) => x.correct));
boot("End to end · answer accuracy (answerable)", e2e.filter((x: any) => x.answerable), (xs) => share(xs, (x) => x.correct));
boot("End to end · abstention on unanswerable", e2e.filter((x: any) => !x.answerable), (xs) => share(xs, (x) => x.correct));
boot("End to end · answering memories retrieved in top 10", e2e.filter((x: any) => x.answerable), (xs) => share(xs, (x) => x.foundAnswersTop10));

const lat = (vals: number[]) => ({ p50: percentile(vals, 50), p95: percentile(vals, 95), n: vals.length });
const latency = {
  extraction: lat(worlds.flatMap((w) => (w.replay?.latency ?? []).map((l: any) => l.extraction))),
  commit: lat(worlds.flatMap((w) => (w.replay?.latency ?? []).map((l: any) => l.commit)).filter((x: number) => x > 0)),
  retrieval: lat([...e2e.map((x: any) => x.latencyMs.retrieval), ...worlds.flatMap((w) => (w.oracle ?? []).map((r: any) => r.latencyMs))]),
  answer: lat(e2e.map((x: any) => x.latencyMs.answer)),
};

const summary = {
  version: 1, synthetic: true, split, smoke, commit: sha, finishedAt: new Date().toISOString(),
  worlds: worlds.length, queries: worlds.reduce((n, w) => n + new Set([...(w.e2e ?? []), ...(w.oracle ?? [])].map((r: any) => r.queryId)).size, 0),
  metrics, attribution: attributionShares(e2e), latency,
  geminiCalls: budget.used(), stoppedEarly: stopped,
  notes: [
    "Synthetic benchmark (eval/stages/data); every history, name and question is generated, labelled in code, worded by Claude.",
    "Extraction precision counts every extracted entity the gold has no label for, including reasonable concept entities.",
    "Relation pair F1 is unordered; typed F1 uses Claude (on the plan) to decide label equivalence.",
    "End-to-end answers are text from gemini-2.5-flash with the production Live prompt and the retrieved context in the system prompt; production uses Live audio and a tool call.",
    "Oracle descriptions use one fixed template, so they read differently from extractor-written descriptions.",
    ...(stopped ? [`Run stopped early (${stopped}); results cover the finished histories only.`] : []),
  ],
};
writeJson(join(runDir, "summary.json"), summary);
writeFileSync(join(runDir, "baseline-report.md"), renderReport(summary));
console.log(`stages: ${worlds.length} histories → ${join(runDir, "baseline-report.md")}`);
if (leftovers.length) console.log(`cleanup: ${leftovers.length} user delete(s) failed; next run's sweep removes them`);
