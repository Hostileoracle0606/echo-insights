export type RerankerDocument = { id: string; text: string };
export type RerankerScore = { id: string; score: number };

export type MemoryReranker = {
  rank(
    query: string,
    documents: RerankerDocument[],
    signal: AbortSignal,
  ): Promise<Map<string, number>>;
};

type HttpRerankerOptions = {
  endpoint: string;
  bearerToken?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
};

const MAX_CANDIDATES = 32;
const MAX_DOCUMENT_CHARS = 8000;

function assertEndpoint(endpoint: string) {
  const url = new URL(endpoint);
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1" ||
    url.hostname === "::1";
  if (url.protocol !== "https:" && !(local && url.protocol === "http:")) {
    throw new TypeError("Reranker endpoint must use HTTPS or loopback HTTP");
  }
  if (url.username || url.password || url.hash) {
    throw new TypeError("Invalid reranker endpoint");
  }
  return url.toString();
}

function validateDocuments(query: string, documents: RerankerDocument[]) {
  if (
    !query.trim() || query.length > 2000 || documents.length < 1 ||
    documents.length > MAX_CANDIDATES
  ) {
    throw new TypeError("Invalid reranker input");
  }
  const ids = new Set<string>();
  for (const document of documents) {
    if (
      !document.id || document.id.length > 100 || ids.has(document.id) ||
      !document.text || document.text.length > MAX_DOCUMENT_CHARS
    ) {
      throw new TypeError("Invalid reranker candidate");
    }
    ids.add(document.id);
  }
}

function parseScores(value: unknown, ids: Set<string>) {
  if (
    !value || typeof value !== "object" ||
    !Array.isArray((value as { scores?: unknown }).scores)
  ) {
    throw new TypeError("Invalid reranker response");
  }
  const rows = (value as { scores: unknown[] }).scores;
  if (rows.length !== ids.size) {
    throw new TypeError("Incomplete reranker response");
  }
  const scores = new Map<string, number>();
  for (const row of rows) {
    if (!row || typeof row !== "object") {
      throw new TypeError("Invalid reranker score");
    }
    const item = row as Record<string, unknown>;
    if (
      typeof item.id !== "string" || !ids.has(item.id) || scores.has(item.id) ||
      typeof item.score !== "number" || !Number.isFinite(item.score)
    ) {
      throw new TypeError("Invalid reranker score");
    }
    scores.set(item.id, item.score);
  }
  return scores;
}

export function rankedCandidatePriorities(
  rows: RerankerScore[],
): Map<string, number> {
  const sorted = [...rows].sort((a, b) =>
    b.score - a.score || a.id.localeCompare(b.id)
  );
  if (
    sorted.some((row, index) =>
      !Number.isFinite(row.score) ||
      sorted.findIndex((item) => item.id === row.id) !== index
    )
  ) {
    throw new TypeError("Invalid reranker ordering");
  }
  return new Map(sorted.map(({ id }, index) => [id, 1 - index / 10_000]));
}

export const DEFAULT_RERANK_BUDGET_MS = 500;

/** Bounds a stage even when its I/O implementation ignores cancellation. */
export async function withRerankDeadline<T>(
  parentSignal: AbortSignal,
  budgetMs: number,
  work: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  parentSignal.throwIfAborted();
  const controller = new AbortController();
  let onAbort!: () => void;
  let timer!: ReturnType<typeof setTimeout>;
  const stop = new Promise<never>((_, reject) => {
    onAbort = () => {
      controller.abort();
      reject(new DOMException("Aborted", "AbortError"));
    };
    parentSignal.addEventListener("abort", onAbort, { once: true });
    timer = setTimeout(() => {
      controller.abort();
      reject(new Error("Reranker deadline exceeded"));
    }, budgetMs);
  });
  try {
    return await Promise.race([work(controller.signal), stop]);
  } finally {
    clearTimeout(timer);
    parentSignal.removeEventListener("abort", onAbort);
  }
}

export function createHttpMemoryReranker(
  options: HttpRerankerOptions,
): MemoryReranker {
  const endpoint = assertEndpoint(options.endpoint);
  const timeoutMs = options.timeoutMs ?? DEFAULT_RERANK_BUDGET_MS;
  const fetchImpl = options.fetchImpl ?? fetch;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 2000) {
    throw new RangeError(
      "Reranker timeout must be between 1 and 2000 milliseconds",
    );
  }
  return {
    async rank(query, documents, parentSignal) {
      validateDocuments(query, documents);
      // Graph IDs can include a user's entity names. The scorer needs only
      // request-local IDs to match responses to candidate texts.
      const idByWireId = new Map<string, string>();
      const wireDocuments = documents.map(({ id, text }, index) => {
        const wireId = `candidate-${index}`;
        idByWireId.set(wireId, id);
        return { id: wireId, text };
      });
      return withRerankDeadline(parentSignal, timeoutMs, async (signal) => {
        const response = await fetchImpl(endpoint, {
          method: "POST",
          redirect: "error",
          signal,
          headers: {
            "content-type": "application/json",
            ...(options.bearerToken
              ? { authorization: `Bearer ${options.bearerToken}` }
              : {}),
          },
          body: JSON.stringify({ query, documents: wireDocuments }),
        });
        if (!response.ok) throw new Error("Reranker unavailable");
        const matched = parseScores(
          await response.json(),
          new Set(idByWireId.keys()),
        );
        return new Map(
          [...matched].map(([id, score]) => [idByWireId.get(id)!, score]),
        );
      });
    },
  };
}

export function crossEncoderPriorityMap(scores: Map<string, number>) {
  return rankedCandidatePriorities(
    [...scores].map(([id, score]) => ({ id, score })),
  );
}
