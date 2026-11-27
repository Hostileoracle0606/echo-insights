import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { DbClient } from "../_shared/db-client.ts";
import type {
  Entity,
  GraphState,
  Relation,
} from "../_shared/graphloop/types.ts";
import { graphEvidence, type MemoryRerankTrace } from "./graph-evidence.ts";
import type { MemoryReranker } from "./memory-reranker.ts";
import { selectRelevant } from "./select.ts";

// Routed recall answers from the graph: the entities that match the question
// (select.ts) and the journal entries linked to them, never a free-text
// passage search. This mirrors staging, where "Where is Priya moving?" failed
// because newer entries that only named Priya crowded out the statement.

const at = (day: number) => `2026-11-${String(day).padStart(2, "0")}T05:00:00Z`;
const e = (id: string, name: string): Entity => ({
  id,
  name,
  type: "other",
  metadata: {},
  mentions: 1,
  firstSeen: at(1),
  lastSeen: at(1),
});
const r = (
  id: string,
  source: string,
  target: string,
  label: string,
): Relation => ({
  id,
  source,
  target,
  label,
  metadata: {},
  createdAt: "",
});
const graph: GraphState = {
  entities: Object.fromEntries(
    [e("priya", "Priya"), e("lisbon", "Lisbon"), e("samsung", "Samsung")].map((
      x,
    ) => [x.id, x]),
  ),
  relations: { r1: r("r1", "priya", "lisbon", "moving_to") },
  entries: [],
};

const mention = (entryId: string, day: number, excerpt: string) => ({
  entryId,
  notebookId: `nb-${entryId}`,
  notebookTitle: "t",
  createdAt: at(day),
  excerpt,
  turnId: null,
  spokenAt: null,
});
const moving = mention(
  "move",
  1,
  "My sister Priya is moving to Lisbon next month.",
);
const mentionsById: Record<string, unknown[]> = {
  priya: [
    mention("p5", 22, "Priya, why you constantly asking me about her?"),
    mention("p4", 21, "She is a software developer."),
    mention("p3", 20, "I'm happy for her."),
    moving,
  ],
  lisbon: [moving, mention("l2", 2, "What is the Belem tower in Lisbon?")],
  samsung: [mention("s1", 3, "I work on AI at Samsung.")],
};

function client(calls: string[] = []): DbClient {
  return {
    auth: { getUser: () => Promise.reject(new Error("unused")) },
    from: () => {
      throw new Error("unused");
    },
    rpc: (name, args) => {
      if (name === "redact_forgotten_text") {
        calls.push("redact_forgotten_text");
        return Promise.resolve({
          data: String(args.p_text).replaceAll(
            "FORGOTTEN_SECRET",
            "[redacted]",
          ),
          error: null,
        });
      }
      calls.push(`${name}:${args.p_entity_id}`);
      return Promise.resolve({
        data: {
          total: 9,
          mentions: mentionsById[args.p_entity_id as string] ?? [],
        },
        error: null,
      });
    },
  };
}
const signal = new AbortController().signal;

Deno.test("evidence is the entries linked to the matched entities, most connected first", async () => {
  const result = await graphEvidence(
    client(),
    graph,
    "Priya move",
    new Map([["priya", 0.9]]),
    signal,
  );
  assertEquals(result.entityIds, ["priya", "lisbon"]);
  // Linked to both Priya and Lisbon: ranked above newer Priya-only entries.
  assertEquals(result.passages[0], {
    entryId: "move",
    notebookId: "nb-move",
    text: "My sister Priya is moving to Lisbon next month.",
    spokenAt: null,
    createdAt: at(1),
  });
  assertEquals(result.passages.some((p) => p.entryId === "s1"), false);
});

Deno.test("no matching entity means no evidence and no entry lookups", async () => {
  const calls: string[] = [];
  const result = await graphEvidence(
    client(calls),
    graph,
    "the weather",
    new Map(),
    signal,
  );
  assertEquals(result, { entityIds: [], passages: [] });
  assertEquals(calls, []);
});

Deno.test("cross-encoder ordering changes selected entities and exposes a private debug trace", async () => {
  let received: Array<{ id: string; text: string }> = [];
  let trace: MemoryRerankTrace | undefined;
  const reranker: MemoryReranker = {
    rank: (_query, documents) => {
      received = documents;
      return Promise.resolve(new Map([["lisbon", 2.2], ["priya", -0.4]]));
    },
  };
  const result = await graphEvidence(
    client(),
    graph,
    "Priya move",
    new Map([["priya", 0.9]]),
    signal,
    {
      reranker,
      debug: (value) => {
        trace = value;
      },
      onBaselineEntityIds: (ids) => assertEquals(ids, ["priya", "lisbon"]),
    },
  );
  assertEquals(result.entityIds, ["lisbon", "priya"]);
  assertEquals(received.map(({ id }) => id), ["priya", "lisbon"]);
  assertEquals(received[0].text.includes("Priya --moving_to--> Lisbon"), true);
  assertEquals(trace?.candidates.map(({ id, score }) => [id, score]), [[
    "priya",
    -0.4,
  ], ["lisbon", 2.2]]);
  assertEquals(trace?.candidates[0].features.denseRank, 1);
  assertEquals(trace?.candidates[0].features.temporalValidity, "unknown");
  assertEquals(trace?.candidates[0].features.provenanceAvailable, false);
  assertEquals(trace?.candidates[0].features.sourceEntryCount, null);
  assertEquals(trace?.baselineIds, ["priya"]);
  assertEquals(trace?.rerankedIds, ["lisbon", "priya"]);
  assertEquals(trace?.paths, [
    { entityId: "lisbon", path: ["priya", "r1", "lisbon"] },
    { entityId: "priya", path: ["priya"] },
  ]);
  assertEquals(trace?.fallback, false);
  assertEquals(typeof trace?.durationMs, "number");
});

Deno.test("reranked selection cannot be outranked by a stage-one exact-name hit", () => {
  const expanded = {
    ...graph,
    entities: {
      ...graph.entities,
      outsider: e("outsider", "Priya moving"),
    },
  };
  const result = selectRelevant(
    expanded,
    "Priya moving",
    new Map([["outsider", 0.99]]),
    new Map([["lisbon", 1], ["priya", 0.9999]]),
  );
  assertEquals(result.seeds, ["lisbon", "priya"]);
  assertEquals(result.entities.some(({ id }) => id === "outsider"), false);
});

Deno.test("Forget redaction runs before candidate text reaches the reranker", async () => {
  const sensitiveGraph = {
    ...graph,
    entities: {
      ...graph.entities,
      priya: {
        ...graph.entities.priya,
        description: "FORGOTTEN_SECRET details",
      },
    },
  };
  const calls: string[] = [];
  let received: Array<{ id: string; text: string }> = [];
  const reranker: MemoryReranker = {
    rank: (_query, docs) => {
      received = docs;
      return Promise.resolve(
        new Map(docs.map(({ id }, index) => [id, 1 - index / 100])),
      );
    },
  };
  await graphEvidence(
    client(calls),
    sensitiveGraph,
    "Priya move",
    new Map([["priya", 0.9]]),
    signal,
    { reranker },
  );
  assertEquals(
    calls.filter((call) => call === "redact_forgotten_text").length,
    received.length,
  );
  assertEquals(
    received.some(({ text }) => text.includes("FORGOTTEN_SECRET")),
    false,
  );
  assertEquals(received.some(({ text }) => text.includes("[redacted]")), true);
});

Deno.test("unavailable cross-encoder uses the existing selector", async () => {
  const reranker: MemoryReranker = {
    rank: () => Promise.reject(new Error("offline")),
  };
  const result = await graphEvidence(
    client(),
    graph,
    "Priya move",
    new Map([["priya", 0.9]]),
    signal,
    { reranker },
  );
  assertEquals(result.entityIds, ["priya", "lisbon"]);
});

Deno.test("the reranking budget covers candidate redaction and preserves baseline evidence", async () => {
  const original = client();
  let release!: () => void;
  const stalled: DbClient = {
    ...original,
    rpc: (name, args) => {
      if (name !== "redact_forgotten_text") return original.rpc(name, args);
      return new Promise((resolve) => {
        release = () => resolve({ data: String(args.p_text), error: null });
      });
    },
  };
  let invoked = false;
  const baseline = await graphEvidence(
    original,
    graph,
    "Samsung",
    undefined,
    signal,
  );
  const actual = await graphEvidence(
    stalled,
    graph,
    "Samsung",
    undefined,
    signal,
    {
      budgetMs: 5,
      reranker: {
        rank: () => {
          invoked = true;
          return Promise.resolve(new Map());
        },
      },
    },
  );
  release();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assertEquals(invoked, false);
  assertEquals(actual, baseline);
});

Deno.test("eval dense and pairwise arms share the exact 20-candidate pool and fallback order", async () => {
  const entities = Array.from({ length: 22 }, (_, index) => e(`entity-${index + 1}`, `Entity ${index + 1}`));
  const wideGraph: GraphState = { entities: Object.fromEntries(entities.map((entity) => [entity.id, entity])), relations: {}, entries: [] };
  const semantic = new Map(entities.map((entity, index) => [entity.id, 0.99 - index / 100]));
  const traceFor = async (arm: "dense" | "dense-pairwise", reranker?: MemoryReranker) => {
    let trace: MemoryRerankTrace | undefined;
    const result = await graphEvidence(client(), wideGraph, "memory query", semantic, signal, {
      evalArm: arm,
      evalTrialId: "trial-123",
      reranker,
      debug: (value) => { trace = value; },
    });
    return { trace, result };
  };
  const dense = await traceFor("dense");
  const pairwiseFallback = await traceFor("dense-pairwise", {
    rank: () => Promise.reject(new Error("scorer unavailable")),
  });
  assertEquals(dense.trace?.candidates.length, 20);
  assertEquals(
    dense.trace?.candidates.map(({ id, hash }) => [id, hash]),
    pairwiseFallback.trace?.candidates.map(({ id, hash }) => [id, hash]),
  );
  assertEquals(pairwiseFallback.trace?.fallback, true);
  assertEquals(pairwiseFallback.trace?.rerankedIds, dense.trace?.rerankedIds);
  assertEquals(pairwiseFallback.result.entityIds, dense.result.entityIds);
  assertEquals(dense.trace?.trialId, "trial-123");
  assertEquals(dense.trace?.candidates.some(({ id }) => id.startsWith("entity-")), false);
});
