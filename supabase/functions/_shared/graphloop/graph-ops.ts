import type { GraphState, Relation } from "./types.ts";

/** Count whitespace-separated words in a string (empty/undefined → 0). */
export const wordCount = (s: string | undefined): number =>
  s ? s.trim().split(/\s+/).filter(Boolean).length : 0;

/** Relations that have not been soft-deleted via supersededAt. */
export const activeRelations = (state: GraphState): Relation[] =>
  Object.values(state.relations).filter((r) => !r.supersededAt);

/** Undirected adjacency built from a relation list. */
export function buildNeighbors(relations: Relation[]): Map<string, Set<string>> {
  const neighbors = new Map<string, Set<string>>();
  for (const r of relations) {
    if (!neighbors.has(r.source)) neighbors.set(r.source, new Set());
    if (!neighbors.has(r.target)) neighbors.set(r.target, new Set());
    neighbors.get(r.source)!.add(r.target);
    neighbors.get(r.target)!.add(r.source);
  }
  return neighbors;
}

/**
 * Uncertainty score (0-3) per active relation. Mirrors the prior inline agenda
 * logic: +1 if mentioned <= once, +1 if endpoints first appeared in different
 * entries, +1 if it is the only active relation for that ordered pair.
 */
export function relationUncertainty(state: GraphState): Map<string, number> {
  const active = activeRelations(state);
  const mentionCountByRelation = new Map<string, number>();
  const firstEntryByEntity = new Map<string, string>();
  // entries are newest-first; iterate reversed so last write = oldest entry
  for (const entry of state.entries.slice().reverse()) {
    for (const rid of entry.relationIds) {
      mentionCountByRelation.set(rid, (mentionCountByRelation.get(rid) ?? 0) + 1);
    }
    for (const eid of entry.entityIds) {
      firstEntryByEntity.set(eid, entry.id);
    }
  }
  const activePairCount = new Map<string, number>();
  for (const r of active) {
    const key = `${r.source} ${r.target}`;
    activePairCount.set(key, (activePairCount.get(key) ?? 0) + 1);
  }
  const scores = new Map<string, number>();
  for (const r of active) {
    let score = 0;
    if ((mentionCountByRelation.get(r.id) ?? 0) <= 1) score += 1;
    const se = firstEntryByEntity.get(r.source);
    const te = firstEntryByEntity.get(r.target);
    if (se && te && se !== te) score += 1;
    if ((activePairCount.get(`${r.source} ${r.target}`) ?? 0) <= 1) score += 1;
    scores.set(r.id, score);
  }
  return scores;
}
