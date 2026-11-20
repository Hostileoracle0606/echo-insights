import type { Embedder } from "../_shared/embedder.ts";

import type { MemoryPassage } from "./memory-query-types.ts";
type RpcResult = { data: unknown; error: unknown };
type RpcRequest = PromiseLike<RpcResult> & {
  abortSignal?: (signal: AbortSignal) => PromiseLike<RpcResult>;
};
export interface PassageRpcClient {
  rpc(name: string, args: Record<string, unknown>): RpcRequest;
}

const MAX_RESULTS = 8;
const MAX_SOURCES = 20;
function cancelled(signal?: AbortSignal): void {
  if (signal?.aborted) throw new DOMException("Aborted", "AbortError");
}
function valid(value: unknown): value is MemoryPassage {
  if (!value || typeof value !== "object") return false;
  const p = value as Record<string, unknown>;
  return typeof p.entryId === "string" && typeof p.notebookId === "string" &&
    typeof p.text === "string" && p.text.length > 0 &&
    typeof p.createdAt === "string" &&
    (p.spokenAt === null || typeof p.spokenAt === "string");
}
async function fetchRows(
  client: PassageRpcClient,
  query: string,
  ids: string[],
  exact: boolean,
  signal?: AbortSignal,
): Promise<MemoryPassage[]> {
  cancelled(signal);
  const request = client.rpc("memory_passage_candidates", {
    p_query: query,
    p_ids: ids.slice(0, MAX_SOURCES),
    p_exact: exact,
  });
  const { data, error } =
    await (signal && request.abortSignal
      ? request.abortSignal(signal)
      : request);
  cancelled(signal);
  if (error) throw new Error("Passage retrieval failed");
  if (!Array.isArray(data)) throw new Error("Invalid passage response");
  const allowed = new Set(ids);
  return data.filter(valid).filter((p) => !exact || allowed.has(p.entryId));
}
export async function readMemoryPassages(
  client: PassageRpcClient,
  sourceIds: string[],
  signal?: AbortSignal,
): Promise<MemoryPassage[]> {
  if (!sourceIds.length) return [];
  return await fetchRows(client, "", [...new Set(sourceIds)], true, signal);
}
function cosine(a: number[], b: number[]): number {
  if (!a.length || a.length !== b.length) return 0;
  let dot = 0, aa = 0, bb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    aa += a[i] ** 2;
    bb += b[i] ** 2;
  }
  return aa && bb ? dot / Math.sqrt(aa * bb) : 0;
}
export async function searchMemoryPassages(
  client: PassageRpcClient,
  embedder: Embedder,
  question: string,
  searchHint = "",
  signal?: AbortSignal,
  sourceIds: string[] = [],
): Promise<MemoryPassage[]> {
  const query = `${question} ${searchHint}`.trim().slice(0, 1000);
  if (!query) return [];
  const candidates = await fetchRows(client, query, sourceIds, false, signal);
  if (!candidates.length) return [];
  let vectors: number[][] = [];
  try {
    vectors = await embedder.embed([query, ...candidates.map((p) => p.text)]);
    if (vectors.length !== candidates.length + 1) vectors = [];
  } catch {
    // Local semantic embedding is optional; lexical and source hits still work.
  }
  cancelled(signal);
  const terms = new Set(query.toLowerCase().match(/[\p{L}\p{N}]{3,}/gu) ?? []);
  const preferred = new Set(sourceIds.slice(0, MAX_SOURCES));
  const ranked = candidates.map((p, i) => {
    const words = new Set(
      p.text.toLowerCase().match(/[\p{L}\p{N}]{3,}/gu) ?? [],
    );
    let overlap = 0;
    for (const term of terms) if (words.has(term)) overlap++;
    return {
      p,
      score: (vectors.length ? cosine(vectors[0], vectors[i + 1]) : 0) +
        overlap / Math.max(terms.size, 1) + (preferred.has(p.entryId) ? 1 : 0),
    };
  }).sort((a, b) => b.score - a.score || a.p.entryId.localeCompare(b.p.entryId))
    .slice(0, MAX_RESULTS);
  const fresh = await readMemoryPassages(
    client,
    ranked.map(({ p }) => p.entryId),
    signal,
  );
  const byId = new Map(fresh.map((p) => [p.entryId, p]));
  return ranked.flatMap(({ p }) => {
    const now = byId.get(p.entryId);
    return now && now.notebookId === p.notebookId && now.text === p.text &&
        now.createdAt === p.createdAt && now.spokenAt === p.spokenAt
      ? [now]
      : [];
  });
}
