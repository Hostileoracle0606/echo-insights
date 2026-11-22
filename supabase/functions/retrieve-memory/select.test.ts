import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { Entity, GraphState, Relation } from "../_shared/graphloop/types.ts";
import { selectRelevant } from "./select.ts";

const NOW = "2026-11-22T06:00:00Z";
const e = (id: string, name: string, description?: string): Entity => ({
  id,
  name,
  type: "other",
  ...(description ? { description } : {}),
  metadata: {},
  mentions: 1,
  firstSeen: NOW,
  lastSeen: NOW,
});
const r = (id: string, source: string, target: string, label: string): Relation => ({
  id,
  source,
  target,
  label,
  metadata: {},
  createdAt: "",
});

// A small account, as on staging: one project, plus unrelated threads.
const graph: GraphState = {
  entities: Object.fromEntries(
    [
      e("lumen-app", "Lumen app", "the user's iOS app"),
      e("launch-checklist", "launch checklist"),
      e("mid-december", "mid December"),
      e("samsung", "Samsung"),
      e("ai", "AI", "enterprise AI project at work"),
      e("europe", "Europe"),
      e("priya", "Priya"),
      e("lisbon", "Lisbon"),
    ].map((x) => [x.id, x]),
  ),
  relations: Object.fromEntries(
    [
      r("r1", "lumen-app", "launch-checklist", "has"),
      r("r2", "lumen-app", "mid-december", "releases_in"),
      r("r3", "ai", "samsung", "at"),
      r("r4", "priya", "lisbon", "moving_to"),
    ].map((x) => [x.id, x]),
  ),
  entries: [],
};

const ids = (result: { entities: Entity[] }) => result.entities.map((x) => x.id);

Deno.test("keeps only matches close to the best one, best first", () => {
  const semantic = new Map([
    ["lumen-app", 0.86],
    ["launch-checklist", 0.82],
    ["samsung", 0.74],
    ["europe", 0.71],
  ]);
  const result = selectRelevant(graph, "where were we with the Lumen project", semantic);
  assertEquals(ids(result).slice(0, 2), ["lumen-app", "launch-checklist"]);
  assertEquals(ids(result).includes("samsung"), false);
  assertEquals(ids(result).includes("europe"), false);
});

Deno.test("adds the best match's direct neighbours, nothing further", () => {
  const result = selectRelevant(graph, "Lumen", new Map([["lumen-app", 0.9]]));
  assertEquals(ids(result), ["lumen-app", "launch-checklist", "mid-december"]);
  assertEquals(result.relations.map((x) => x.id).sort(), ["r1", "r2"]);
});

Deno.test("a word in a description is not a match on its own", () => {
  // "project" appears only in AI's description: no semantic score, no name.
  const result = selectRelevant(graph, "project", new Map());
  assertEquals(ids(result), []);
  assertEquals(result.context, "");
});

Deno.test("an exact name in the query qualifies without a semantic score", () => {
  const result = selectRelevant(graph, "how is Priya doing", undefined);
  assertEquals(ids(result), ["priya", "lisbon"]);
});

Deno.test("at most three matches are kept, however close", () => {
  const semantic = new Map([
    ["priya", 0.9],
    ["lisbon", 0.9],
    ["europe", 0.89],
    ["samsung", 0.89],
    ["ai", 0.88],
  ]);
  const result = selectRelevant(graph, "travel", semantic);
  assertEquals(result.seeds.length, 3);
});

Deno.test("nothing relevant returns nothing, not a summary of everything", () => {
  const result = selectRelevant(graph, "the weather", new Map());
  assertEquals(result.entities, []);
  assertEquals(result.communities, undefined);
});

Deno.test("a query that is part of a name matches, a little below a full name", () => {
  const g: GraphState = {
    entities: {
      "priya-nair": e("priya-nair", "Priya Nair"),
      "work-project": e("work-project", "Work project"),
      priya: e("priya", "Priya"),
    },
    relations: {},
    entries: [],
  };
  assertEquals(ids(selectRelevant(g, "work", undefined)), ["work-project"]);
  // The full name wins; the partial one is within the margin only if close.
  assertEquals(ids(selectRelevant(g, "Priya", undefined)), ["priya"]);
});
