import type { DbClient } from "../_shared/db-client.ts";
import type { GraphState } from "../_shared/graphloop/types.ts";
import type { MemoryPassage } from "./memory-query-types.ts";
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

type Linked = { passage: MemoryPassage; entities: Set<string>; firstEntity: number };

async function linkedEntries(
  client: DbClient,
  entityIds: string[],
  signal: AbortSignal,
): Promise<Map<string, Linked>> {
  const responses = await Promise.all(entityIds.map((id) =>
    client.rpc("get_entity_mentions", { p_entity_id: id, p_limit: ENTRIES_PER_ENTITY })
  ));
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
        typeof m.excerpt !== "string" || !m.excerpt || typeof m.createdAt !== "string"
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
): Promise<GraphEvidence> {
  const entityIds = selectRelevant(graph, query, semantic).entities.map((entity) => entity.id);
  if (!entityIds.length) return { entityIds: [], passages: [] };
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
  return { entityIds, passages };
}

/** The cited entries as they are now, read through the same graph links. */
export async function rereadEvidence(
  client: DbClient,
  entityIds: string[],
  sourceIds: string[],
  signal: AbortSignal,
): Promise<MemoryPassage[]> {
  if (!entityIds.length || !sourceIds.length) return [];
  const linked = await linkedEntries(client, entityIds, signal);
  return sourceIds.flatMap((id) => {
    const entry = linked.get(id);
    return entry ? [entry.passage] : [];
  });
}
