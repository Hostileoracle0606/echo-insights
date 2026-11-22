import type { DbClient } from "../_shared/db-client.ts";
import { MAX_QUOTES } from "../_shared/retrieve-memory-contract.ts";
import { EvidenceUnavailable } from "./evidence.ts";
import {
  type MemoryPassage,
  memoryQueryResponse,
  type MemoryRoute,
  type MemoryVerdict,
} from "./memory-query-types.ts";
import { clip } from "./quotes.ts";

export type MemoryQueryDeps = {
  timeoutMs?: number;
  route(question: string, signal: AbortSignal): Promise<MemoryRoute | null>;
  resolve(
    question: string,
    route: MemoryRoute,
    passages: MemoryPassage[],
    signal: AbortSignal,
  ): Promise<MemoryVerdict>;
};

/**
 * Where routed recall gets its evidence: the graph only (graph-evidence.ts).
 * [evidence] returns the entries linked to the entities matching the query;
 * [reread] reads the cited ones again, the same way, before answering.
 */
export type GraphEvidenceSource = {
  evidence(query: string, signal: AbortSignal): Promise<MemoryPassage[]>;
  reread(sourceIds: string[], signal: AbortSignal): Promise<MemoryPassage[]>;
};

async function redact(
  client: DbClient,
  input: string,
  signal: AbortSignal,
): Promise<string> {
  signal.throwIfAborted();
  const { data, error } = await client.rpc("redact_forgotten_text", {
    p_text: input,
  });
  signal.throwIfAborted();
  if (error || typeof data !== "string") {
    throw new Error("Memory redaction unavailable");
  }
  return data.trim();
}

export async function runMemoryQuery(
  deps: MemoryQueryDeps,
  client: DbClient,
  question: string,
  hint: string,
  startedAt: number,
  graph: GraphEvidenceSource,
  log: (fields: Record<string, unknown>) => void,
) {
  const controller = new AbortController();
  const { signal } = controller;
  const remaining = (deps.timeoutMs ?? 3000) - (Date.now() - startedAt);
  if (remaining <= 0) return memoryQueryResponse();

  const record = (outcome: string, details: Record<string, unknown> = {}) => {
    log({
      scope: "user",
      version: 3,
      outcome,
      latencyMs: Date.now() - startedAt,
      ...details,
    });
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  const expired = new Promise<ReturnType<typeof memoryQueryResponse>>(
    (resolve) => {
      timer = setTimeout(() => {
        controller.abort();
        record("timeout");
        resolve(memoryQueryResponse());
      }, remaining);
    },
  );

  const work = async () => {
    const [safeQuestion, safeHint] = await Promise.all([
      redact(client, question, signal),
      hint ? redact(client, hint, signal) : Promise.resolve(""),
    ]);
    if (safeQuestion.length < 2) return memoryQueryResponse();
    const route = await deps.route(safeQuestion, signal);
    signal.throwIfAborted();
    if (!route || route.operation === "conversation") {
      record(route ? "conversation" : "route_fallback");
      if (route) {
        return memoryQueryResponse({
          status: "conversation",
          text: "Continue the conversation normally.",
          sourceIds: [],
        });
      }
      return memoryQueryResponse({
        status: "clarification",
        text: "I couldn't check your journal just now. Could you ask again?",
        sourceIds: [],
      });
    }

    const passages = await graph.evidence(safeHint || safeQuestion, signal);
    signal.throwIfAborted();
    if (!passages.length) {
      record("no_graph_match", route);
      return memoryQueryResponse();
    }
    const verdict = await deps.resolve(safeQuestion, route, passages, signal);
    signal.throwIfAborted();
    if (
      verdict.status === "insufficient_evidence" ||
      verdict.status === "conversation"
    ) {
      record("insufficient_evidence", route);
      return memoryQueryResponse();
    }

    const text = await redact(client, verdict.text, signal);
    if (!text || text !== verdict.text || text.length > 1500) {
      return memoryQueryResponse();
    }
    if (verdict.status === "clarification" && !verdict.sourceIds.length) {
      record("clarification", route);
      return memoryQueryResponse({
        status: "clarification",
        text,
        sourceIds: [],
      });
    }

    const selected = new Map(passages.map((p) => [p.entryId, p]));
    const sourceIds = [...new Set(verdict.sourceIds)];
    if (!sourceIds.length || sourceIds.some((id) => !selected.has(id))) {
      return memoryQueryResponse();
    }
    const fresh = new Map(
      (await graph.reread(sourceIds, signal)).map((p) => [p.entryId, p]),
    );
    signal.throwIfAborted();
    if (
      sourceIds.some((id) => {
        const old = selected.get(id)!;
        const current = fresh.get(id);
        return !current || current.notebookId !== old.notebookId ||
          current.text !== old.text ||
          current.spokenAt !== old.spokenAt ||
          current.createdAt !== old.createdAt;
      })
    ) {
      record("source_changed", route);
      return memoryQueryResponse();
    }

    if (verdict.status === "clarification") {
      record("clarification", route);
      return memoryQueryResponse({
        status: "clarification",
        text,
        sourceIds: [],
      });
    }

    record("supported", { ...route, sourceCount: sourceIds.length });
    return memoryQueryResponse(
      { status: "supported", text, sourceIds },
      sourceIds.slice(0, MAX_QUOTES).map((id) => {
        const passage = fresh.get(id)!;
        return {
          entryId: passage.entryId,
          notebookId: passage.notebookId,
          text: clip(passage.text),
          spokenAt: passage.spokenAt,
          createdAt: passage.createdAt,
          notebookTitle: "",
          turnId: null,
        };
      }),
    );
  };

  try {
    return await Promise.race([work(), expired]);
  } catch (error) {
    if (!signal.aborted && error instanceof EvidenceUnavailable) {
      record("evidence_unavailable", { providerStatus: error.status });
      return memoryQueryResponse({
        status: "clarification",
        text: "I couldn't check your journal just now. Could you ask again?",
        sourceIds: [],
      });
    }
    if (!signal.aborted) record("workflow_unavailable");
    return memoryQueryResponse();
  } finally {
    clearTimeout(timer);
  }
}
