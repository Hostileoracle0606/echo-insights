// Ranking and classification metrics. Pure functions over ids.

export function prf(tp, fp, fn) {
  const precision = tp + fp ? tp / (tp + fp) : 0;
  const recall = tp + fn ? tp / (tp + fn) : 0;
  const f1 = precision + recall ? (2 * precision * recall) / (precision + recall) : 0;
  return { precision, recall, f1 };
}

/** Share of gold ids in the first k ranked ids; null when there is no gold (not scored). */
export function recallAt(ranked, goldIds, k) {
  if (!goldIds.length) return null;
  const top = new Set(ranked.slice(0, k));
  return goldIds.filter((g) => top.has(g)).length / goldIds.length;
}

/** 1 / rank of the first gold id, 0 when none is ranked. */
export function mrr(ranked, goldIds) {
  const gold = new Set(goldIds);
  const i = ranked.findIndex((id) => gold.has(id));
  return i < 0 ? 0 : 1 / (i + 1);
}

/** NDCG@k with graded gold ([{entityId, relevance}]), gain 2^rel - 1, log2(rank + 1) discount. */
export function ndcgAt(ranked, gradedGold, k) {
  const rel = new Map(gradedGold.map((g) => [g.entityId, g.relevance]));
  const gain = (r) => 2 ** r - 1;
  const dcg = ranked.slice(0, k).reduce((sum, id, i) => sum + gain(rel.get(id) ?? 0) / Math.log2(i + 2), 0);
  const ideal = [...rel.values()].sort((a, b) => b - a).slice(0, k);
  const idcg = ideal.reduce((sum, r, i) => sum + gain(r) / Math.log2(i + 2), 0);
  return idcg ? dcg / idcg : null;
}

/** Nearest-rank percentile (p in 0..100). */
export function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.max(1, Math.ceil((p / 100) * sorted.length));
  return sorted[rank - 1];
}
