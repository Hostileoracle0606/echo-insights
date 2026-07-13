import { describe, expect, test } from "vitest";
import type { Entity, GraphState, Relation } from "./types";
import { activeRelations, buildNeighbors, relationUncertainty } from "./graph-ops";

const T = "2026-06-12T00:00:00.000Z";
const ent = (id: string, name: string): Entity => ({
  id,
  name,
  type: "concept",
  metadata: {},
  mentions: 1,
  firstSeen: T,
  lastSeen: T,
});
const rel = (source: string, target: string, label: string): Relation => ({
  id: `${source}__${label}__${target}`,
  source,
  target,
  label,
  metadata: {},
  createdAt: T,
});

// Two people both linked to "atlas", surfaced in separate entries.
const seed = (): GraphState => {
  const r1 = rel("maya", "atlas", "on");
  const r2 = rel("sam", "atlas", "on");
  return {
    entities: { maya: ent("maya", "Maya"), sam: ent("sam", "Sam"), atlas: ent("atlas", "Atlas") },
    relations: { [r1.id]: r1, [r2.id]: r2 },
    entries: [
      {
        id: "e1",
        text: "Maya on Atlas",
        createdAt: T,
        entityIds: ["maya", "atlas"],
        relationIds: [r1.id],
      },
      {
        id: "e2",
        text: "Sam on Atlas",
        createdAt: T,
        entityIds: ["sam", "atlas"],
        relationIds: [r2.id],
      },
    ],
  };
};

describe("graph-ops", () => {
  test("activeRelations excludes superseded relations", () => {
    const s = seed();
    const rid = Object.keys(s.relations)[0]!;
    s.relations[rid] = { ...s.relations[rid]!, supersededAt: T };
    expect(activeRelations(s).map((r) => r.id)).not.toContain(rid);
  });

  test("buildNeighbors is symmetric", () => {
    const n = buildNeighbors(activeRelations(seed()));
    expect(n.get("maya")?.has("atlas")).toBe(true);
    expect(n.get("atlas")?.has("maya")).toBe(true);
  });

  test("relationUncertainty scores a single fresh cross-entry relation >= 2", () => {
    const scores = relationUncertainty(seed());
    const first = [...scores.values()][0]!;
    expect(first).toBeGreaterThanOrEqual(2);
  });
});
