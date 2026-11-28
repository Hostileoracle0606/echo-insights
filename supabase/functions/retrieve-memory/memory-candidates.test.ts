import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { Entity, GraphState, Relation } from "../_shared/graphloop/types.ts";
import { collectMemoryCandidates, memoryCandidateDocument } from "./memory-candidates.ts";

const entity = (id: string, name: string, lastSeen = "2026-11-26T00:00:00Z"): Entity => ({
  id, name, type: "event", description: `${name} plan`, metadata: {}, mentions: 2,
  firstSeen: lastSeen, lastSeen,
});
const relation = (id: string, source: string, target: string, label: string): Relation => ({
  id, source, target, label, metadata: {}, createdAt: "2026-11-26T00:00:00Z",
});
const graph: GraphState = {
  entities: Object.fromEntries([
    entity("photo", "Vancouver photography trip"),
    entity("reunion", "Vancouver reunion trip", "2026-10-01T00:00:00Z"),
    entity("vancouver", "Vancouver"),
    entity("july", "July"),
    entity("irrelevant", "Dinner reservation"),
  ].map((item) => [item.id, item])),
  relations: Object.fromEntries([
    relation("r1", "photo", "vancouver", "to"),
    relation("r2", "reunion", "vancouver", "to"),
    relation("r3", "reunion", "july", "in"),
    relation("r4", "photo", "irrelevant", "unrelated"),
  ].map((item) => [item.id, item])),
  entries: [],
};

Deno.test("stage one merges dense, lexical and active graph candidates with auditable features", () => {
  const candidates = collectMemoryCandidates(graph, "Vancouver reunion trip", new Map([
    ["photo", 0.83], ["unknown", 0.99], ["irrelevant", 0.72],
  ]), { now: Date.parse("2026-11-26T12:00:00Z"), maxCandidates: 10 });
  assertEquals(candidates.map(({ id }) => id), ["photo", "july", "reunion", "irrelevant", "vancouver"]);
  const reunion = candidates.find(({ id }) => id === "reunion")!;
  assertEquals(reunion.features.denseRank, null);
  assertEquals(reunion.features.lexicalRank, 1);
  assertEquals(reunion.features.graphDistance, 0);
  assertEquals(reunion.features.activeRelationCount, 2);
  assertEquals(reunion.features.ageDays, 56.5);
  assertEquals(reunion.features.entityOverlap, 1);
  assertEquals(candidates.some(({ id }) => id === "unknown"), false);
  assertEquals(memoryCandidateDocument(graph, "reunion"),
    "Vancouver reunion trip (event)\nVancouver reunion trip plan\nVancouver reunion trip --to--> Vancouver\nVancouver reunion trip --in--> July");
});

Deno.test("stage one excludes superseded graph paths", () => {
  const supersededGraph: GraphState = {
    ...graph,
    relations: Object.fromEntries(Object.entries(graph.relations).map(([id, item]) => [
      id, { ...item, ...(id === "r4" ? { supersededAt: "2026-11-26T00:00:00Z" } : {}) },
    ])),
  };
  const candidates = collectMemoryCandidates(supersededGraph, "nothing matches", new Map([["irrelevant", 0.9]]), {
    now: Date.parse("2026-11-26T12:00:00Z"), maxCandidates: 2,
  });
  assertEquals(candidates.map(({ id }) => id), ["irrelevant"]);
});
