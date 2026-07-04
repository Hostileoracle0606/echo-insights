// Retrieval evaluation harness — runs the REAL deployed retrieval pipeline
// (SearchIndex + buildCommunities + retrieve + buildContext) over designed
// "transcript-derived" scenarios with ground-truth expectations, and reports
// accuracy metrics. Run: ~/.deno/bin/deno run -A supabase/functions/retrieve-memory/eval.ts
import { retrieve } from "../_shared/graphloop/retrieve.ts";
import { SearchIndex } from "../_shared/graphloop/search-index.ts";
import { buildCommunities } from "../_shared/graphloop/communities.ts";
import type { Entity, GraphEntry, GraphState, Relation } from "../_shared/graphloop/types.ts";
import { buildContext } from "./context.ts";

const NOW = "2026-06-27T12:00:00Z";
const daysAgo = (n: number) => new Date(Date.parse(NOW) - n * 86_400_000).toISOString();

type EntOpts = Partial<Pick<Entity, "mentions" | "firstSeen" | "lastSeen" | "description" | "questions">>;
const ent = (id: string, name: string, type: Entity["type"], o: EntOpts = {}): Entity => ({
  id, name, type, metadata: {}, mentions: o.mentions ?? 1,
  firstSeen: o.firstSeen ?? NOW, lastSeen: o.lastSeen ?? NOW,
  description: o.description, questions: o.questions,
});
const rel = (id: string, source: string, label: string, target: string, supersededAt?: string): Relation =>
  ({ id, source, target, label, metadata: {}, createdAt: NOW, supersededAt });
const entry = (id: string, text: string, entityIds: string[], relationIds: string[] = []): GraphEntry =>
  ({ id, text, createdAt: NOW, entityIds, relationIds });
const graph = (entities: Entity[], relations: Relation[], entries: GraphEntry[] = []): GraphState => ({
  entities: Object.fromEntries(entities.map((e) => [e.id, e])),
  relations: Object.fromEntries(relations.map((r) => [r.id, r])),
  entries,
});

interface Scenario {
  id: string;
  behavior: string;       // what this experiment verifies
  query: string;
  state: GraphState;
  expectRelevant: string[]; // entity NAMES that should be retrieved (ground truth)
  forbidden?: string[];     // entity NAMES that must NOT be retrieved
  expectTop?: string;       // entity NAME that should rank #1
  expectEmpty?: boolean;    // expect zero entities (global/empty fallback)
  sentinel?: string;        // string that must NEVER appear in the returned context
}

const scenarios: Scenario[] = [
  {
    id: "S1 direct-recall",
    behavior: "Query names an entity → that entity + its 1-hop neighbour are recalled",
    query: "atlas",
    state: graph(
      [ent("atlas", "Atlas", "project", { description: "a migration project", mentions: 4 }),
       ent("maya", "Maya", "person", { mentions: 3 })],
      [rel("r1", "maya", "works_on", "atlas")],
      [entry("e1", "I worked on Atlas with Maya today", ["maya", "atlas"], ["r1"])],
    ),
    expectRelevant: ["Atlas", "Maya"],
  },
  {
    id: "S2 bm25-description",
    behavior: "Seed via BM25 on the DESCRIPTION field (query word not in the name)",
    query: "burnout demo",
    state: graph(
      [ent("anxiety", "anxiety", "emotion", { description: "recurring worry about the launch demo and burnout", mentions: 2 }),
       ent("atlas", "Atlas", "project")],
      [rel("r1", "anxiety", "about", "atlas")],
    ),
    expectRelevant: ["anxiety"],
  },
  {
    id: "S3 khop-boundary",
    behavior: "k-hop BFS includes hops 0-2 and EXCLUDES hop 3 (default hops=2)",
    query: "alpha",
    state: graph(
      [ent("A", "Alpha", "concept"), ent("B", "Beta", "concept"),
       ent("C", "Gamma", "concept"), ent("D", "Delta", "concept")],
      [rel("r1", "A", "links", "B"), rel("r2", "B", "links", "C"), rel("r3", "C", "links", "D")],
    ),
    expectRelevant: ["Alpha", "Beta", "Gamma"],
    forbidden: ["Delta"],
  },
  {
    id: "S4 composite-ranking",
    behavior: "When 2 entities both match, recency + importance rank the stronger one #1",
    query: "migration",
    state: graph(
      [ent("atlas", "Atlas", "project", { description: "the big migration effort", mentions: 8, lastSeen: NOW }),
       ent("phoenix", "Phoenix", "project", { description: "an old migration attempt", mentions: 1, firstSeen: daysAgo(120), lastSeen: daysAgo(120) })],
      [],
    ),
    expectRelevant: ["Atlas", "Phoenix"],
    expectTop: "Atlas",
  },
  {
    id: "S5 superseded-excluded",
    behavior: "A superseded relation is inactive → its endpoint is NOT pulled in as a neighbour",
    query: "atlas",
    state: graph(
      [ent("atlas", "Atlas", "project"), ent("sam", "Sam", "person"), ent("maya", "Maya", "person")],
      [rel("r_old", "maya", "works_on", "atlas", NOW),  // superseded
       rel("r_new", "sam", "works_on", "atlas")],       // active
    ),
    expectRelevant: ["Atlas", "Sam"],
    forbidden: ["Maya"],
  },
  {
    id: "S6 no-seed-fallback",
    behavior: "Query with no lexical/name match → empty (source-free) result, no crash",
    query: "quantumchromodynamics",
    state: graph(
      [ent("atlas", "Atlas", "project"), ent("maya", "Maya", "person")],
      [rel("r1", "maya", "works_on", "atlas")],
    ),
    expectRelevant: [],
    expectEmpty: true,
  },
  {
    id: "S7 privacy-no-source-leak",
    behavior: "Verbatim entry text (a secret) NEVER appears in the returned context",
    query: "atlas",
    state: graph(
      [ent("atlas", "Atlas", "project", { mentions: 2 }), ent("maya", "Maya", "person")],
      [rel("r1", "maya", "works_on", "atlas")],
      [entry("e1", "My SSN is SENTINEL-078-05-1120 and Maya is on Atlas", ["maya", "atlas"], ["r1"])],
    ),
    expectRelevant: ["Atlas", "Maya"],
    sentinel: "SENTINEL-078-05-1120",
  },
];

interface Row {
  id: string; precision: number; recall: number; f1: number;
  topOk: boolean; forbiddenLeak: string[]; sentinelLeak: boolean; emptyOk: boolean;
  latencyMs: number; pass: boolean; retrieved: string[];
}

async function run(s: Scenario): Promise<Row> {
  const idx = new SearchIndex();
  await idx.sync(Object.values(s.state.entities));
  const communities = buildCommunities(s.state);
  const t0 = performance.now();
  const result = await retrieve(s.state, s.query, { mode: "lexical" }, { index: idx, communities });
  const latencyMs = performance.now() - t0;
  const ctx = buildContext(result);

  const retrieved = result.entities.map((e) => e.name);
  const relSet = new Set(s.expectRelevant);
  const tp = retrieved.filter((n) => relSet.has(n)).length;
  const precision = retrieved.length ? tp / retrieved.length : (s.expectEmpty ? 1 : 0);
  const recall = relSet.size ? tp / relSet.size : 1;
  const f1 = precision + recall ? (2 * precision * recall) / (precision + recall) : (s.expectEmpty ? 1 : 0);

  const forbiddenLeak = (s.forbidden ?? []).filter((n) => retrieved.includes(n));
  const topOk = s.expectTop ? retrieved[0] === s.expectTop : true;
  const sentinelLeak = s.sentinel ? ctx.includes(s.sentinel) : false;
  const emptyOk = s.expectEmpty === undefined ? true : (result.entities.length === 0) === s.expectEmpty;

  // Pass = perfect recall, no forbidden leak, no sentinel leak, top-1 correct, empty-expectation met.
  const pass = recall === 1 && forbiddenLeak.length === 0 && !sentinelLeak && topOk && emptyOk;
  return { id: s.id, precision, recall, f1, topOk, forbiddenLeak, sentinelLeak, emptyOk, latencyMs, pass, retrieved };
}

const rows: Row[] = [];
for (const s of scenarios) rows.push(await run(s));

const pct = (n: number) => (n * 100).toFixed(0) + "%";
console.log("\n=== RETRIEVAL EVAL ===");
for (let i = 0; i < rows.length; i++) {
  const r = rows[i];
  console.log(
    `${r.pass ? "PASS" : "FAIL"}  ${r.id.padEnd(24)} P=${pct(r.precision)} R=${pct(r.recall)} F1=${pct(r.f1)} ` +
    `top=${r.topOk ? "ok" : "WRONG"} forbidLeak=${r.forbiddenLeak.length ? r.forbiddenLeak.join(",") : "none"} ` +
    `srcLeak=${r.sentinelLeak ? "LEAK!" : "no"} ${r.latencyMs.toFixed(2)}ms`,
  );
  console.log(`      · ${scenarios[i].behavior}`);
  console.log(`      · retrieved: [${r.retrieved.join(", ")}]`);
}
const passed = rows.filter((r) => r.pass).length;
const avg = (f: (r: Row) => number) => rows.reduce((a, r) => a + f(r), 0) / rows.length;
console.log(
  `\n=== SUMMARY: ${passed}/${rows.length} passed | macro-P ${pct(avg((r) => r.precision))} ` +
  `macro-R ${pct(avg((r) => r.recall))} macro-F1 ${pct(avg((r) => r.f1))} | ` +
  `p50 latency ${[...rows].map((r) => r.latencyMs).sort((a, b) => a - b)[Math.floor(rows.length / 2)].toFixed(2)}ms ===`,
);
if (passed !== rows.length) Deno.exit(1);
