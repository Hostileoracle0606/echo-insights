import { normalizeName } from "../_shared/graphloop/noise.ts";
import { activeRelations, buildNeighbors } from "../_shared/graphloop/graph-ops.ts";
import type { GraphState, Relation } from "../_shared/graphloop/types.ts";

export type MemoryCandidateFeatures = {
  denseRank: number | null;
  lexicalRank: number | null;
  graphDistance: number;
  entityOverlap: number;
  ageDays: number | null;
  temporalValidity: "unknown";
  activeRelationCount: number;
  sourceEntryCount: number | null;
  provenanceAvailable: boolean;
};

export type MemoryCandidate = {
  id: string;
  features: MemoryCandidateFeatures;
};

export type MemoryCandidateOptions = {
  maxCandidates?: number;
  denseLimit?: number;
  graphHops?: number;
  now?: number;
};

const MAX_CANDIDATES = 32;
const MAX_GRAPH_HOPS = 2;
const MAX_NAME_SEEDS = 12;

function rankedDenseSeeds(graph: GraphState, semantic: Map<string, number>, limit = 12) {
  return [...semantic.entries()]
    .filter(([id, score]) => graph.entities[id] && Number.isFinite(score))
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit)
    .map(([id]) => id);
}

function rankedLexicalSeeds(graph: GraphState, query: string) {
  const normalizedQuery = normalizeName(query).replace(/\s+/g, " ").trim();
  if (!normalizedQuery) return [];
  const words = new Set(normalizedQuery.split(" ").filter((word) => word.length > 1));
  return Object.values(graph.entities)
    .map((entity) => {
      const name = normalizeName(entity.name).replace(/\s+/g, " ").trim();
      const description = normalizeName(entity.description ?? "").replace(/\s+/g, " ").trim();
      const exactName = name.length >= 2 && ` ${normalizedQuery} `.includes(` ${name} `);
      const partialName = normalizedQuery.length >= 3 && ` ${name} `.includes(` ${normalizedQuery} `);
      const entityWords = new Set(`${name} ${description}`.split(" ").filter((word) => word.length > 1));
      const overlap = words.size ? [...words].filter((word) => entityWords.has(word)).length / words.size : 0;
      return { id: entity.id, nameMatch: Number(exactName || partialName), overlap };
    })
    .filter(({ nameMatch, overlap }) => nameMatch > 0 || overlap > 0)
    .sort((a, b) => b.nameMatch - a.nameMatch || b.overlap - a.overlap || a.id.localeCompare(b.id))
    .slice(0, MAX_NAME_SEEDS)
    .map(({ id }) => id);
}

function graphDistances(graph: GraphState, roots: string[], maxHops: number) {
  const neighbors = buildNeighbors(activeRelations(graph));
  const distance = new Map(roots.map((id) => [id, 0]));
  let frontier = roots;
  for (let hop = 1; hop <= maxHops; hop++) {
    const next: string[] = [];
    for (const id of frontier) {
      for (const neighbor of neighbors.get(id) ?? []) {
        if (!distance.has(neighbor) && graph.entities[neighbor]) {
          distance.set(neighbor, hop);
          next.push(neighbor);
        }
      }
    }
    frontier = next;
  }
  return distance;
}

export function memoryCandidateDocument(graph: GraphState, id: string): string {
  const entity = graph.entities[id];
  if (!entity) return "";
  const lines = [`${entity.name} (${entity.type})`, entity.description ?? ""];
  for (const relation of activeRelations(graph)) {
    if (relation.source !== id && relation.target !== id) continue;
    const source = graph.entities[relation.source];
    const target = graph.entities[relation.target];
    if (source && target) lines.push(`${source.name} --${relation.label}--> ${target.name}`);
  }
  return lines.filter(Boolean).join("\n");
}

/** Build a broad set from dense hits, name/text matches and their active graph neighborhood. */
export function collectMemoryCandidates(
  graph: GraphState,
  query: string,
  semantic: Map<string, number> = new Map(),
  options: MemoryCandidateOptions = {},
): MemoryCandidate[] {
  const maxCandidates = options.maxCandidates ?? MAX_CANDIDATES;
  const graphHops = options.graphHops ?? MAX_GRAPH_HOPS;
  if (!Number.isInteger(maxCandidates) || maxCandidates < 1 || maxCandidates > MAX_CANDIDATES) {
    throw new RangeError(`maxCandidates must be between 1 and ${MAX_CANDIDATES}`);
  }
  if (!Number.isInteger(graphHops) || graphHops < 0 || graphHops > MAX_GRAPH_HOPS) {
    throw new RangeError(`graphHops must be between 0 and ${MAX_GRAPH_HOPS}`);
  }
  const dense = rankedDenseSeeds(graph, semantic, options.denseLimit ?? 12);
  const lexical = rankedLexicalSeeds(graph, query);
  const roots = [...new Set([...dense, ...lexical])];
  const distances = graphDistances(graph, roots, graphHops);
  const lexicalRank = new Map(lexical.map((id, index) => [id, index + 1]));
  const denseRank = new Map(dense.map((id, index) => [id, index + 1]));
  const queryWords = new Set(normalizeName(query).split(/\s+/).filter((word) => word.length > 1));
  const relations = activeRelations(graph);
  const relatedByEntity = new Map<string, Relation[]>();
  for (const relation of relations) {
    for (const id of [relation.source, relation.target]) {
      if (!graph.entities[id]) continue;
      const related = relatedByEntity.get(id) ?? [];
      related.push(relation);
      relatedByEntity.set(id, related);
    }
  }
  const sourceCount = new Map<string, number>();
  const provenanceAvailable = graph.entries.length > 0;
  for (const entry of graph.entries) {
    for (const id of new Set([...entry.entityIds, ...entry.relationIds.flatMap((relationId) => {
      const relation = graph.relations[relationId];
      return relation ? [relation.source, relation.target] : [];
    })])) sourceCount.set(id, (sourceCount.get(id) ?? 0) + 1);
  }
  const now = options.now ?? Date.now();
  const candidates = [...distances.entries()]
    .filter(([id]) => Boolean(graph.entities[id]))
    .map(([id, distance]) => ({
      id,
      distance,
      fusion: (denseRank.has(id) ? 1 / (60 + denseRank.get(id)!) : 0) +
        (lexicalRank.has(id) ? 1 / (60 + lexicalRank.get(id)!) : 0) +
        (distance > 0 ? 1 / (60 + distance) : 0),
    }))
    .sort((a, b) => b.fusion - a.fusion || a.id.localeCompare(b.id))
    .slice(0, maxCandidates);
  return candidates.map(({ id, distance: graphDistance }) => {
    const entity = graph.entities[id];
    const words = new Set(normalizeName(`${entity.name} ${entity.description ?? ""}`).split(/\s+/));
    const candidate: MemoryCandidate = {
      id,
      features: {
        denseRank: denseRank.get(id) ?? null,
        lexicalRank: lexicalRank.get(id) ?? null,
        graphDistance,
        entityOverlap: queryWords.size ? [...queryWords].filter((word) => words.has(word)).length / queryWords.size : 0,
        ageDays: Number.isFinite(Date.parse(entity.lastSeen))
          ? Math.max(0, (now - Date.parse(entity.lastSeen)) / 86_400_000)
          : null,
        temporalValidity: "unknown",
        activeRelationCount: relatedByEntity.get(id)?.length ?? 0,
        sourceEntryCount: provenanceAvailable ? sourceCount.get(id) ?? 0 : null,
        provenanceAvailable,
      },
    };
    return candidate;
  });
}
