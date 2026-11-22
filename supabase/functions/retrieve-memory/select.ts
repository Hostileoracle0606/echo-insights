import { normalizeName } from "../_shared/graphloop/noise.ts";
import type { Entity, GraphState, Relation, RetrievalResult } from "../_shared/graphloop/types.ts";

/**
 * Which part of the user's memory answers a live recall (get_relevant_memory).
 *
 * The general retriever unions keyword hits (no minimum score), exact names
 * and semantic matches, expands two hops and ranks by relevance, recency,
 * importance and confidence. On a small or new account recency and
 * importance are nearly equal everywhere, so the 24-entity budget returned
 * most of the graph, and Lumen listed it. Here meaning decides:
 *
 * - a match is an entity whose embedding is close to the query (the
 *   semantic score, already at least 0.7) or whose name the query contains;
 * - only matches within [SELECTION.margin] of the best one count, at most
 *   [SELECTION.maxMatches] of them, best first;
 * - the best match brings its direct neighbours (what was said about it),
 *   nothing further;
 * - no match returns nothing.
 */
export const SELECTION = {
  margin: 0.06,
  maxMatches: 3,
  maxNeighbours: 3,
};

/** A whole name in the query scores 1; the query as whole words of a name
 * ("Priya" in "Priya Nair") scores [PARTIAL_NAME], so a full name wins. */
const PARTIAL_NAME = 0.9;

function nameScores(g: GraphState, query: string): Map<string, number> {
  const q = normalizeName(query).replace(/\s+/g, " ");
  const words = ` ${q} `;
  const scores = new Map<string, number>();
  for (const entity of Object.values(g.entities)) {
    const name = normalizeName(entity.name).replace(/\s+/g, " ");
    if (name.length >= 2 && words.includes(` ${name} `)) {
      scores.set(entity.id, 1);
    } else if (q.length >= 3 && ` ${name} `.includes(words)) {
      scores.set(entity.id, PARTIAL_NAME);
    }
  }
  return scores;
}

export function selectRelevant(
  g: GraphState,
  query: string,
  semantic: Map<string, number> | undefined,
): RetrievalResult {
  const scores = nameScores(g, query);
  for (const [id, score] of semantic ?? []) {
    if (g.entities[id]) scores.set(id, Math.max(scores.get(id) ?? 0, score));
  }
  const ranked = [...scores.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  if (ranked.length === 0) {
    return { entities: [], relations: [], entries: [], seeds: [], context: "" };
  }

  const best = ranked[0][1];
  const seeds = ranked
    .filter(([, score]) => score >= best - SELECTION.margin)
    .slice(0, SELECTION.maxMatches)
    .map(([id]) => id);

  const kept = new Set(seeds);
  const relations = Object.values(g.relations);
  let neighbours = 0;
  for (const relation of relations) {
    if (neighbours >= SELECTION.maxNeighbours) break;
    const other = relation.source === seeds[0]
      ? relation.target
      : relation.target === seeds[0]
      ? relation.source
      : null;
    if (other && g.entities[other] && !kept.has(other)) {
      kept.add(other);
      neighbours += 1;
    }
  }

  const seedSet = new Set(seeds);
  const keptRelations: Relation[] = relations.filter((relation) =>
    kept.has(relation.source) && kept.has(relation.target) &&
    (seedSet.has(relation.source) || seedSet.has(relation.target))
  );
  const entities: Entity[] = [...kept].map((id) => g.entities[id]);
  return { entities, relations: keptRelations, entries: [], seeds, context: "" };
}
