// Candidate pool, card text and seed selection for the memory reranker: a copy of
// ml/embedding/validation/rerank_core.ts on branch feat/reranker, the code the
// reranker was evaluated with (core.test.ts pins its outputs).
export function candidateIds(
  entities: Record<string, { id: string; name: string }>,
  query: string,
  semanticIds: string[],
  normalizeName: (value: string) => string,
): string[] {
  const normalized = normalizeName(query).replace(/\s+/g, " ");
  const words = ` ${normalized} `;
  const candidates = new Set(semanticIds.filter((id) => Object.hasOwn(entities, id)));
  // Match the user-scope selector's full-name and whole-query partial-name rules.
  for (const entity of Object.values(entities)) {
    const name = normalizeName(entity.name).replace(/\s+/g, " ");
    if ((name.length >= 2 && words.includes(` ${name} `)) ||
        (normalized.length >= 3 && ` ${name} `.includes(words))) {
      candidates.add(entity.id);
    }
  }
  return [...candidates].sort();
}

export function selectReranked<T>(
  candidates: string[],
  logits: number[],
  seedCount: number,
  select: (priorities: Map<string, number>) => T,
): T {
  if (logits.length !== candidates.length || logits.some((logit) => !Number.isFinite(logit))) {
    throw new Error("Expected one finite score per candidate");
  }
  if (!Number.isInteger(seedCount) || seedCount < 0 || seedCount > Math.min(candidates.length, 3)) {
    throw new Error("Invalid seed count for reranking");
  }
  const order = candidates.map((id, index) => ({ id, logit: logits[index] }))
    .sort((a, b) => b.logit - a.logit || a.id.localeCompare(b.id))
    .slice(0, seedCount);
  // Pass only the selected seeds to the production selector. Priorities encode
  // their order within its 0.06 margin so it still owns neighbor expansion.
  return select(new Map(order.map(({ id }, index) => [id, 1 - index / 100])));
}
export type RerankGraph = {
  entities: Record<string, { id: string; name: string; type: string; description?: string }>;
  relations: Record<string, { source: string; target: string; label: string }>;
};

export function candidateDocument(graph: RerankGraph, id: string) {
  const entity = graph.entities[id];
  const lines = [`${entity.name} (${entity.type})`, entity.description ?? ""];
  for (const { source, target, label } of Object.values(graph.relations)) {
    if ((source === id || target === id) && graph.entities[source] && graph.entities[target]) {
      lines.push(`${graph.entities[source].name} --${label}--> ${graph.entities[target].name}`);
    }
  }
  return lines.filter(Boolean).join("\n");
}
