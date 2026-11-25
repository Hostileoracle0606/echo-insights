/**
 * Builds one benchmark split:
 *   npm run eval:stages:gen -- --split train|val|test --worlds N [--seed S] [--smoke] [--concurrency C]
 *
 * Worlds come from world.mjs (code-decided ground truth); Claude writes the
 * language on the owner's plan (write.mjs). Claude outputs are cached in the
 * split's writer-cache.json, so a rebuild costs nothing and is reproducible.
 * Resumable: existing worlds are kept; a plan usage limit stops cleanly.
 * Fails (exit 1) when any text collides with another split (leakage.mjs).
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { PlanLimitReached, assertPlanAuth, createPlanRunner } from "../../lib/claude-plan.mjs";
import { dedupe, leakageReport } from "./leakage.mjs";
import { SPLITS } from "./names.mjs";
import { WorldSchema } from "./schema.mjs";
import { makeWorld } from "./world.mjs";
import { WorldDropped, writeWorld } from "./write.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const args = process.argv.slice(2);
const flag = (name: string) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const split = flag("--split") ?? "";
if (!SPLITS.includes(split)) { console.error("build: --split must be train, val or test"); process.exit(2); }
const smoke = args.includes("--smoke");
const count = Number(flag("--worlds") ?? (smoke ? 3 : 0));
// Disjoint seed ranges per split: a world's history never repeats across splits.
const SEED_BASE: Record<string, number> = { train: 1, val: 10001, test: 20001 };
const start = Number(flag("--seed") ?? SEED_BASE[split]);
const concurrency = Number(flag("--concurrency") ?? 2);

const dataRoot = join(root, "eval/stages/data", smoke ? "smoke" : "");
const dir = join(dataRoot, split);
mkdirSync(dir, { recursive: true });
const worldsPath = join(dir, "worlds.jsonl");
const cachePath = join(dir, "writer-cache.json");
const readJsonl = (p: string) => (existsSync(p) ? readFileSync(p, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);

const cacheData: Record<string, unknown> = existsSync(cachePath) ? JSON.parse(readFileSync(cachePath, "utf8")) : {};
const cache = { get: (k: string) => cacheData[k], set: (k: string, v: unknown) => { cacheData[k] = v; } };
const saveCache = () => writeFileSync(cachePath, `${JSON.stringify(cacheData)}\n`);

const existing = new Map(readJsonl(worldsPath).map((w) => [w.world.id, w]));
const dropped: Array<{ id: string; errors: string[] }> = [];
let stopped: string | null = null;

await assertPlanAuth();
const runner = createPlanRunner();
const seeds = Array.from({ length: count }, (_, i) => start + i);
const todo = seeds.map((seed) => makeWorld({ seed, split })).filter((w) => !existing.has(w.id));

async function worker() {
  while (todo.length && !stopped) {
    const world = todo.shift()!;
    const parsed = WorldSchema.safeParse(world);
    if (!parsed.success) { dropped.push({ id: world.id, errors: [`schema: ${parsed.error.issues[0]?.message}`] }); continue; }
    try {
      const written = await writeWorld({ world, runner, cache });
      existing.set(world.id, { world, written });
      console.log(`build ${world.id}: ${written.turns.length} turns, ${written.queries.length} questions`);
    } catch (error) {
      if (error instanceof WorldDropped) { dropped.push({ id: world.id, errors: error.errors }); console.log(`build ${world.id}: dropped`); continue; }
      if (error instanceof PlanLimitReached) { stopped = error.message; break; }
      throw error;
    } finally {
      saveCache();
    }
  }
}
await Promise.all(Array.from({ length: concurrency }, worker));

// Within-split dedup of questions (keep the first of near-identical ones).
const records = [...existing.values()].sort((a, b) => a.world.seed - b.world.seed);
const queryItems = records.flatMap((r) => r.written.queries.map((q: { id: string; text: string }) => ({ id: q.id, kind: "query", text: q.text })));
const keptIds = new Set(dedupe(queryItems).map((q) => q.id));
const removedDuplicates = queryItems.filter((q) => !keptIds.has(q.id)).map((q) => q.id);

writeFileSync(worldsPath, records.map((r) => JSON.stringify(r)).join("\n") + (records.length ? "\n" : ""));

// Leakage against every other split already built (same data root).
const items = (recs: any[]) => recs.flatMap((r) => [
  ...r.written.turns.map((t: { session: number; text: string }, i: number) => ({ id: `${r.world.id}-t${i + 1}`, kind: "turn", text: t.text })),
  ...r.written.queries.map((q: { id: string; text: string }) => ({ id: q.id, kind: "query", text: q.text })),
]);
const others = SPLITS.filter((s) => s !== split).flatMap((s) => readJsonl(join(dataRoot, s, "worlds.jsonl")));
const leakage = leakageReport(items(records), items(others));

const generatorCommit = execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: root }).toString().trim();
const manifest = {
  synthetic: true,
  split,
  smoke,
  generatorCommit,
  writer: "Claude (opus) via Claude Code headless on the owner's plan",
  seeds: { start, requested: count },
  counts: {
    worlds: records.length,
    queries: queryItems.length - removedDuplicates.length,
    answerable: records.flatMap((r) => r.world.queries).filter((q: { id: string; answerable: boolean }) => q.answerable && keptIds.has(q.id)).length,
    byFamily: Object.fromEntries([...new Set(records.flatMap((r) => r.world.queries.map((q: { family: string }) => q.family)))].map((f) => [f,
      records.flatMap((r) => r.world.queries).filter((q: { id: string; family: string }) => q.family === f && keptIds.has(q.id)).length])),
  },
  droppedWorlds: dropped,
  removedDuplicateQueries: removedDuplicates,
  leakage: leakage.length ? leakage : "clean",
  stoppedByPlanLimit: stopped,
};
writeFileSync(join(dir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`build ${split}: ${records.length} worlds, ${manifest.counts.queries} questions, ${dropped.length} dropped, leakage ${leakage.length ? `${leakage.length} collisions` : "clean"}${stopped ? `; stopped by plan limit (${stopped})` : ""}`);
process.exit(leakage.length ? 1 : 0);
