import { describe, expect, test } from "vitest";
import type { Entity, GraphState, Relation } from "./types";
import { buildCommunities } from "./communities";

const T = "2026-06-12T00:00:00.000Z";
const ent = (id: string): Entity => ({
  id,
  name: id.toUpperCase(),
  type: "concept",
  metadata: {},
  mentions: 1,
  firstSeen: T,
  lastSeen: T,
});
const rel = (source: string, target: string): Relation => ({
  id: `${source}__rel__${target}`,
  source,
  target,
  label: "rel",
  metadata: {},
  createdAt: T,
});
const state = (rels: Relation[]): GraphState => {
  const entities: Record<string, Entity> = {};
  const relations: Record<string, Relation> = {};
  for (const r of rels) {
    entities[r.source] ??= ent(r.source);
    entities[r.target] ??= ent(r.target);
    relations[r.id] = r;
  }
  return { entities, relations, entries: [] };
};

describe("buildCommunities", () => {
  test("returns empty for a graph with no active relations", () => {
    expect(buildCommunities({ entities: { a: ent("a") }, relations: {}, entries: [] })).toEqual([]);
  });

  test("separates two disconnected clusters into communities", () => {
    const comms = buildCommunities(
      state([rel("a1", "a2"), rel("a2", "a3"), rel("b1", "b2"), rel("b2", "b3")]),
    );
    expect(comms.length).toBeGreaterThanOrEqual(2);
    expect(comms[0]!.topEntities.length).toBeGreaterThan(0);
    expect(comms[0]!.label.length).toBeGreaterThan(0);
  });
});
