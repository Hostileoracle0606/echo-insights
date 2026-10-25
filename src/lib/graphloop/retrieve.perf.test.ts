// CPU cost of one get_relevant_memory call inside the retrieve-memory edge
// function: it rebuilds the search index and communities from the whole graph
// on every request, then ranks. The edge function runs this same code (a
// vendored copy in supabase/functions/_shared/graphloop).
//
// Run: npx vitest run src/lib/graphloop/retrieve.perf.test.ts
import { describe, expect, test } from "vitest";
import type { Entity, GraphState, Relation } from "./types";
import { SearchIndex } from "./search-index";
import { retrieve } from "./retrieve";
import { buildCommunities } from "./communities";

const T = "2026-10-01T00:00:00.000Z";
const TYPES: Entity["type"][] = ["person", "place", "project", "concept", "activity", "emotion"];

function graph(n: number): GraphState {
  let seed = 7;
  const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const entities: Record<string, Entity> = {};
  for (let i = 0; i < n; i++) {
    entities[`e${i}`] = {
      id: `e${i}`,
      name: `Entity ${i}`,
      type: TYPES[i % TYPES.length],
      description: i % 2 ? undefined : `Entity ${i} is something the user mentions about work and friends.`,
      metadata: {},
      mentions: 1 + Math.floor(rand() * 12),
      firstSeen: T,
      lastSeen: T,
    };
  }
  const relations: Record<string, Relation> = {};
  for (let i = 0; i < Math.round(n * 1.5); i++) {
    const s = Math.floor(rand() * n);
    const t = (s + 1 + Math.floor(rand() * (n - 1))) % n;
    const id = `e${s}__related_to__e${t}`;
    relations[id] = { id, source: `e${s}`, target: `e${t}`, label: "related_to", metadata: {}, createdAt: T };
  }
  return { entities, relations, entries: [] } as unknown as GraphState;
}

async function oneRequest(g: GraphState) {
  // The same three steps the handler runs per request (handler.ts `rank`).
  const index = new SearchIndex();
  await index.sync(Object.values(g.entities));
  const communities = buildCommunities(g);
  return retrieve(g, "Entity 42 and the project", { mode: "lexical" }, { index, communities });
}

describe("retrieve-memory per-request CPU", () => {
  for (const n of [200, 1000, 2000]) {
    test(`user-scope graph, n=${n}`, async () => {
      const g = graph(n);
      await oneRequest(g);
      const samples: number[] = [];
      for (let i = 0; i < 7; i++) {
        const t0 = performance.now();
        await oneRequest(g);
        samples.push(performance.now() - t0);
      }
      samples.sort((a, b) => a - b);
      const median = samples[3];
      console.log(`PERF retrieve_request n=${n} median=${median.toFixed(2)}ms worst=${samples[6].toFixed(2)}ms`);
      // Gemini waits on this inside a 3.5 s budget that also covers 4+ network hops.
      expect(median).toBeLessThan(n <= 200 ? 100 : 2000);
    });
  }
});
