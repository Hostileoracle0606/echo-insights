import type { DbClient } from "../_shared/db-client.ts";
import type { GraphState } from "../_shared/graphloop/types.ts";
import type { MemoryPassage } from "./memory-query-types.ts";
import {
  collectMemoryCandidates,
  memoryCandidateDocument,
} from "./memory-candidates.ts";
import {
  crossEncoderPriorityMap,
  DEFAULT_RERANK_BUDGET_MS,
  type MemoryReranker,
  withRerankDeadline,
} from "./memory-reranker.ts";
import { selectRelevant } from "./select.ts";

/**
 * Evidence for routed recall, from the graph only.
 *
 * The entities that match the question are chosen by meaning (select.ts).
 * Their linked journal entries (get_entity_mentions, which reads the
 * Forget-redacted text) become the evidence the resolver may cite. There is
 * no free-text passage search: an entry is evidence only because the graph
 * links it to a matching entity.
 *
 * Ranking is structural. An entry linked to more of the selected entities
 * comes first ("Priya is moving to Lisbon" is linked to both Priya and
 * Lisbon), then the order the entities were selected in, then newest.
 */
export const ENTRIES_PER_ENTITY = 8;
export const MAX_EVIDENCE = 12;

export type GraphEvidence = { entityIds: string[]; passages: MemoryPassage[] };

export type MemoryRerankTrace = {
  arm?: "baseline" | "dense" | "dense-pairwise";
  trialId?: string;
  candidates: Array<{
    id: string;
    hash?: string;
    score: number | null;
    features: ReturnType<typeof collectMemoryCandidates>[number]["features"];
  }>;
  baselineIds: string[];
  rerankedIds: string[];
  retainedEntryIds?: string[];
  baselineEntityHashes?: string[];
  selectedEntityHashes?: string[];
  baselineSeedHashes?: string[];
  selectedSeedHashes?: string[];
  paths: Array<{ entityId: string; path: string[] }>;
  fallback: boolean;
  durationMs: number | null;
};

async function idHash(id: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(id));
  return [...new Uint8Array(digest)].slice(0, 8).map((part) => part.toString(16).padStart(2, "0")).join("");
}

export type GraphEvidenceOptions = {
  /** Private switch for isolated local paired evaluations. */
  evalArm?: "baseline" | "dense" | "dense-pairwise";
  evalTrialId?: string;
  reranker?: MemoryReranker;
  debug?: (trace: MemoryRerankTrace) => void;
  rerankQuery?: string;
  candidateCount?: number;
  budgetMs?: number;
  onBaselineEntityIds?: (ids: string[]) => void;
};

type Linked = {
  passage: MemoryPassage;
  entities: Set<string>;
  firstEntity: number;
};

async function linkedEntries(
  client: DbClient,
  entityIds: string[],
  signal: AbortSignal,
): Promise<Map<string, Linked>> {
  const responses = await Promise.all(
    entityIds.map((id) =>
      client.rpc("get_entity_mentions", {
        p_entity_id: id,
        p_limit: ENTRIES_PER_ENTITY,
      })
    ),
  );
  signal.throwIfAborted();
  const byEntry = new Map<string, Linked>();
  responses.forEach(({ data, error }, index) => {
    if (error) throw new Error("Linked entries unavailable");
    const mentions = (data as { mentions?: unknown } | null)?.mentions;
    if (!Array.isArray(mentions)) throw new Error("Invalid linked entries");
    for (const raw of mentions) {
      const m = raw as Record<string, unknown>;
      if (
        typeof m.entryId !== "string" || typeof m.notebookId !== "string" ||
        typeof m.excerpt !== "string" || !m.excerpt ||
        typeof m.createdAt !== "string"
      ) continue;
      const existing = byEntry.get(m.entryId);
      if (existing) {
        existing.entities.add(entityIds[index]);
        continue;
      }
      byEntry.set(m.entryId, {
        passage: {
          entryId: m.entryId,
          notebookId: m.notebookId,
          text: m.excerpt,
          spokenAt: typeof m.spokenAt === "string" ? m.spokenAt : null,
          createdAt: m.createdAt,
        },
        entities: new Set([entityIds[index]]),
        firstEntity: index,
      });
    }
  });
  return byEntry;
}

export async function graphEvidence(
  client: DbClient,
  graph: GraphState,
  query: string,
  semantic: Map<string, number> | undefined,
  signal: AbortSignal,
  options: GraphEvidenceOptions = {},
): Promise<GraphEvidence> {
  const evaluationStartedAt = Date.now();
  const baselineSeeds = options.evalArm && semantic ? new Map([...semantic].slice(0, 12)) : semantic;
  const baseline = selectRelevant(graph, query, baselineSeeds);
  options.onBaselineEntityIds?.(baseline.entities.map((entity) => entity.id));
  let selected = baseline;
  const evalArm = options.evalArm;
  let evalTrace: MemoryRerankTrace | undefined;
  const reranker = options.reranker;
  if (evalArm) {
    const denseLimit = evalArm === "baseline" ? 12 : 20;
    const candidates = [...(semantic ?? new Map<string, number>())]
      .filter(([id, score]) => Object.hasOwn(graph.entities, id) && Number.isFinite(score))
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, denseLimit)
      .map(([id, score], index) => ({
        id,
        features: { denseRank: index + 1, lexicalRank: null, graphDistance: 0, entityOverlap: 0,
          ageDays: null, activeRelationCount: 0, sourceEntryCount: null,
          provenanceAvailable: false, temporalValidity: "unknown" as const },
        score,
      }));
    let scores: Map<string, number> | undefined;
    let fallback = false;
    if (evalArm === "baseline") {
      selected = baseline;
    } else if (evalArm === "dense") {
      selected = selectRelevant(graph, query, undefined, new Map(
        candidates.map((candidate, index) => [candidate.id, 1 - index / 10_000]),
      ));
    } else if (reranker && candidates.length) {
      try {
        scores = await withRerankDeadline(
          signal,
          options.budgetMs ?? DEFAULT_RERANK_BUDGET_MS,
          async (stageSignal) => {
            const documents = await Promise.all(candidates.map(async ({ id }) => {
              const { data, error } = await client.rpc("redact_forgotten_text", {
                p_text: memoryCandidateDocument(graph, id),
              });
              if (error || typeof data !== "string") throw new Error("Candidate redaction unavailable");
              return { id, text: data.trim() };
            }));
            stageSignal.throwIfAborted();
            if (!documents.length || documents.some(({ text }) => !text)) {
              throw new Error("Dense candidate pool is not fully eligible");
            }
            const ranked = await reranker.rank(options.rerankQuery ?? query, documents, stageSignal);
            stageSignal.throwIfAborted();
            if (ranked.size !== documents.length || documents.some(({ id }) => !ranked.has(id))) {
              throw new Error("Reranker returned incomplete scores");
            }
            return ranked;
          },
        );
        selected = selectRelevant(graph, query, undefined, crossEncoderPriorityMap(scores));
      } catch {
        if (signal.aborted) throw new DOMException("Aborted", "AbortError");
        fallback = true;
        selected = selectRelevant(graph, query, undefined, new Map(
          candidates.map((candidate, index) => [candidate.id, 1 - index / 10_000]),
        ));
      }
    } else {
      fallback = true;
      selected = selectRelevant(graph, query, undefined, new Map(
        candidates.map((candidate, index) => [candidate.id, 1 - index / 10_000]),
      ));
    }
    // Trace identifiers are request-local ordinals; graph IDs may contain names.
    const ordinal = new Map(candidates.map(({ id }, index) => [id, `candidate-${index + 1}`]));
    evalTrace = {
        arm: evalArm,
        trialId: options.evalTrialId,
        candidates: await Promise.all(candidates.map(async ({ id, features }) => ({
          id: ordinal.get(id)!, hash: await idHash(id), score: scores?.get(id) ?? null, features,
        }))),
        baselineIds: baseline.seeds.map((id) => ordinal.get(id) ?? "outside-pool"),
        rerankedIds: selected.seeds.map((id) => ordinal.get(id) ?? "outside-pool"),
        paths: selected.seeds.map((id) => ({
          entityId: ordinal.get(id) ?? "outside-pool",
          path: graphPath(graph, candidates.map(({ id: root }) => root), id)
            .map((pathId) => ordinal.get(pathId) ?? "outside-pool"),
        })),
        fallback,
        durationMs: Date.now() - evaluationStartedAt,
        baselineEntityHashes: await Promise.all(baseline.entities.map(({ id }) => idHash(id))),
        selectedEntityHashes: await Promise.all(selected.entities.map(({ id }) => idHash(id))),
        baselineSeedHashes: await Promise.all(baseline.seeds.map(idHash)),
        selectedSeedHashes: await Promise.all(selected.seeds.map(idHash)),
      };
  } else if (reranker) {
    const candidates = collectMemoryCandidates(graph, query, semantic, {
      maxCandidates: options.candidateCount,
    });
    if (candidates.length) {
      const startedAt = Date.now();
      let scores: Map<string, number> | undefined;
      let fallback = false;
      try {
        scores = await withRerankDeadline(
          signal,
          options.budgetMs ?? DEFAULT_RERANK_BUDGET_MS,
          async (stageSignal) => {
            // Descriptions and edge labels may contain forgotten text.
            const documents =
              (await Promise.all(candidates.map(async ({ id }) => {
                const { data, error } = await client.rpc(
                  "redact_forgotten_text",
                  {
                    p_text: memoryCandidateDocument(graph, id),
                  },
                );
                if (error || typeof data !== "string") {
                  throw new Error("Candidate redaction unavailable");
                }
                return { id, text: data.trim() };
              }))).filter(({ text }) => text.length > 0);
            stageSignal.throwIfAborted();
            if (!documents.length) {
              throw new Error("No eligible reranker candidates");
            }
            const ranked = await reranker.rank(
              options.rerankQuery ?? query,
              documents,
              stageSignal,
            );
            stageSignal.throwIfAborted();
            if (
              ranked.size !== documents.length ||
              documents.some(({ id }) => !ranked.has(id))
            ) {
              throw new Error("Reranker returned incomplete scores");
            }
            return ranked;
          },
        );
        selected = selectRelevant(
          graph,
          query,
          semantic,
          crossEncoderPriorityMap(scores),
        );
      } catch {
        if (signal.aborted) throw new DOMException("Aborted", "AbortError");
        fallback = true;
        selected = baseline;
      }
      try {
        options.debug?.({
          candidates: candidates.map(({ id, features }) => ({
            id,
            score: scores?.get(id) ?? null,
            features,
          })),
          baselineIds: baseline.seeds,
          rerankedIds: fallback ? baseline.seeds : selected.seeds,
          paths: (fallback ? baseline.seeds : selected.seeds).map((id) => ({
            entityId: id,
            path: graphPath(
              graph,
              candidates.filter((candidate) =>
                candidate.features.graphDistance === 0
              )
                .map((candidate) => candidate.id),
              id,
            ),
          })),
          fallback,
          durationMs: Date.now() - startedAt,
        });
      } catch { /* debug tooling never affects retrieval */ }
    }
  }
  const entityIds = selected.entities.map((entity) => entity.id);
  if (!entityIds.length) {
    if (evalTrace) {
      evalTrace.retainedEntryIds = [];
      try { options.debug?.(evalTrace); } catch { /* debug tooling never affects retrieval */ }
    }
    return { entityIds: [], passages: [] };
  }
  const linked = await linkedEntries(client, entityIds, signal);
  const passages = [...linked.values()]
    .sort((a, b) =>
      b.entities.size - a.entities.size ||
      a.firstEntity - b.firstEntity ||
      Date.parse(b.passage.createdAt) - Date.parse(a.passage.createdAt) ||
      a.passage.entryId.localeCompare(b.passage.entryId)
    )
    .slice(0, MAX_EVIDENCE)
    .map((entry) => entry.passage);
  if (evalTrace) {
    evalTrace.retainedEntryIds = await Promise.all(passages.map(({ entryId }) => idHash(entryId)));
    try { options.debug?.(evalTrace); } catch { /* debug tooling never affects retrieval */ }
  }
  return { entityIds, passages };
}

function graphPath(
  graph: GraphState,
  roots: string[],
  target: string,
): string[] {
  const rootSet = new Set(roots);
  if (rootSet.has(target)) return [target];
  const active = Object.values(graph.relations).filter((relation) =>
    !relation.supersededAt
  );
  const neighbors = new Map<
    string,
    Array<{ id: string; relationId: string }>
  >();
  for (const relation of active) {
    for (
      const [from, id] of [[relation.source, relation.target], [
        relation.target,
        relation.source,
      ]]
    ) {
      const rows = neighbors.get(from) ?? [];
      rows.push({ id, relationId: relation.id });
      neighbors.set(from, rows);
    }
  }
  const previous = new Map<string, { id: string; relationId: string }>();
  const queue = roots.filter((id) => graph.entities[id]);
  const seen = new Set(queue);
  for (let offset = 0; offset < queue.length; offset++) {
    const current = queue[offset];
    for (const next of neighbors.get(current) ?? []) {
      if (!graph.entities[next.id] || seen.has(next.id)) continue;
      previous.set(next.id, { id: current, relationId: next.relationId });
      if (next.id === target) {
        const path = [target];
        let cursor = target;
        while (previous.has(cursor)) {
          const step = previous.get(cursor)!;
          path.unshift(step.id, step.relationId);
          cursor = step.id;
        }
        return path;
      }
      seen.add(next.id);
      queue.push(next.id);
    }
  }
  return [];
}
