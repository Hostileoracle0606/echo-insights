import { describe, expect, it, test } from "vitest";
import type { Entity, GraphState, Relation } from "./types";
import { SearchIndex } from "./search-index";
import { retrieve } from "./retrieve";
import { buildCommunities } from "./communities";

const FIXED_NOW = Date.parse("2026-06-12T00:00:00.000Z");
const T = "2026-06-12T00:00:00.000Z";

const ent = (id: string, name: string, type: Entity["type"]): Entity => ({
  id,
  name,
  type,
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

const fixture = (): GraphState => {
  const r1 = rel("maya", "project-atlas", "leads");
  const r2 = rel("sam", "project-atlas", "works_on");
  const r3 = rel("lin", "coffee", "likes");
  return {
    entities: {
      maya: ent("maya", "Maya", "person"),
      "project-atlas": ent("project-atlas", "Project Atlas", "project"),
      sam: ent("sam", "Sam", "person"),
      lin: ent("lin", "Lin", "person"),
      coffee: ent("coffee", "coffee", "concept"),
    },
    relations: { [r1.id]: r1, [r2.id]: r2, [r3.id]: r3 },
    entries: [
      {
        id: "e1",
        text: "Maya leads Project Atlas",
        createdAt: T,
        entityIds: ["maya", "project-atlas"],
        relationIds: [r1.id],
      },
      {
        id: "e2",
        text: "Sam works on Project Atlas",
        createdAt: T,
        entityIds: ["sam", "project-atlas"],
        relationIds: [r2.id],
      },
      {
        id: "e3",
        text: "Lin likes coffee",
        createdAt: T,
        entityIds: ["lin", "coffee"],
        relationIds: [r3.id],
      },
    ],
  };
};

const makeIndex = async (s: GraphState) => {
  const idx = new SearchIndex();
  await idx.sync(Object.values(s.entities));
  return idx;
};

describe("retrieve (local, lexical)", () => {
  test("returns the seed and its neighborhood, excludes unrelated", async () => {
    const s = fixture();
    const r = await retrieve(s, "atlas", {}, { index: await makeIndex(s), now: FIXED_NOW });
    const names = r.entities.map((e) => e.name);
    expect(names).toContain("Project Atlas");
    expect(names).toContain("Maya"); // 1-hop neighbor
    expect(names).not.toContain("coffee"); // unrelated subgraph
  });

  test("attaches provenance entries for retrieved nodes", async () => {
    const s = fixture();
    const r = await retrieve(s, "atlas", {}, { index: await makeIndex(s), now: FIXED_NOW });
    expect(r.entries.some((e) => e.text.includes("Maya leads Project Atlas"))).toBe(true);
  });

  test("packs a context string with entities, relations, and sources", async () => {
    const s = fixture();
    const r = await retrieve(s, "atlas", {}, { index: await makeIndex(s), now: FIXED_NOW });
    expect(r.context).toContain("Project Atlas");
    expect(r.context).toMatch(/--leads-->|--works_on-->/);
    expect(r.context).toContain("## Sources");
  });

  test("empty query returns empty result", async () => {
    const s = fixture();
    const r = await retrieve(s, "   ", {}, { index: await makeIndex(s), now: FIXED_NOW });
    expect(r.entities).toEqual([]);
    expect(r.context).toBe("");
  });

  test("never returns a dangling relation (both endpoints kept)", async () => {
    const s = fixture();
    const r = await retrieve(
      s,
      "atlas",
      { maxEntities: 2 },
      { index: await makeIndex(s), now: FIXED_NOW },
    );
    const keptIds = new Set(r.entities.map((e) => e.id));
    for (const rl of r.relations) {
      expect(keptIds.has(rl.source) && keptIds.has(rl.target)).toBe(true);
    }
  });

  test("excludes superseded relations from expansion", async () => {
    const s = fixture();
    const rid = "maya__leads__project-atlas";
    s.relations[rid] = { ...s.relations[rid]!, supersededAt: T };
    const r = await retrieve(s, "maya", {}, { index: await makeIndex(s), now: FIXED_NOW });
    expect(r.relations.map((rl) => rl.id)).not.toContain(rid);
  });

  test("falls back to community summaries when no seed matches", async () => {
    const s = fixture();
    const r = await retrieve(
      s,
      "totallyunrelatedquery",
      {},
      { index: await makeIndex(s), now: FIXED_NOW, communities: buildCommunities(s) },
    );
    expect(r.entities).toEqual([]);
    expect(r.communities?.length ?? 0).toBeGreaterThan(0);
    expect(r.context).toContain("Relevant areas of memory");
  });
});

describe("retrieve extraSeeds", () => {
  const now = "2026-07-05T00:00:00Z";
  const state: GraphState = {
    entities: {
      northwind: { id: "northwind", name: "Northwind", type: "project", metadata: {}, mentions: 2, firstSeen: now, lastSeen: now, description: "a venture-backed company" },
    },
    relations: {},
    entries: [],
  };

  async function run(extraSeeds?: Map<string, number>) {
    const index = new SearchIndex();
    await index.sync(Object.values(state.entities));
    return retrieve(state, "startup", { mode: "lexical" }, { index, extraSeeds });
  }

  it("does NOT seed a no-lexical-overlap entity without extraSeeds", async () => {
    const r = await run();
    expect(r.entities.map((e) => e.id)).not.toContain("northwind");
  });

  it("seeds it when extraSeeds supplies it", async () => {
    const r = await run(new Map([["northwind", 0.9]]));
    expect(r.entities.map((e) => e.id)).toContain("northwind");
  });
});
