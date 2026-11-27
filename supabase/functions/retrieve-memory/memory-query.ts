import type { DbClient } from "../_shared/db-client.ts";
import type { MemoryFact } from "../_shared/memory-fact-contract.ts";
import { MAX_QUOTES } from "../_shared/retrieve-memory-contract.ts";
import { answerFromFacts, type FactEntity } from "./fact-answers.ts";
import { fallbackRoute } from "./fallback-route.ts";
import {
  type MemoryPassage,
  memoryQueryResponse,
  type MemoryRoute,
} from "./memory-query-types.ts";
import { clip } from "./quotes.ts";

export type MemoryQueryDeps = {
  timeoutMs?: number;
  route(question: string, signal: AbortSignal): Promise<MemoryRoute | null>;
};

/**
 * Where routed recall reads from: the graph and the fact layer only.
 * [evidence] returns the entries linked to the entities matching the query
 * (graph-evidence.ts); [facts] returns those same entities with every live
 * fact stored for them (EC-06).
 */
export type GraphEvidenceSource = {
  evidence(query: string, signal: AbortSignal, rerankQuery?: string): Promise<MemoryPassage[]>;
  facts(signal: AbortSignal): Promise<{ entities: FactEntity[]; facts: MemoryFact[] }>;
};

/**
 * The user's own words, for Live to answer from: open recall ("What did I
 * say about Priya?"), and any exact question no stored fact answers.
 */
export const OPEN_RECALL_TEXT =
  "These are the user's own past words that match. Answer from them in your own words.";

function isOpenRecall(route: MemoryRoute): boolean {
  return route.operation === "recall" && route.timeScope === "unspecified";
}

function toQuote(passage: MemoryPassage) {
  return {
    entryId: passage.entryId,
    notebookId: passage.notebookId,
    text: clip(passage.text),
    spokenAt: passage.spokenAt,
    createdAt: passage.createdAt,
    notebookTitle: "",
    turnId: null,
  };
}

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

  const quotesAnswer = (
    passages: MemoryPassage[],
    route: MemoryRoute,
    outcome: string,
    extra: Record<string, unknown> = {},
  ) => {
    const shown = passages.slice(0, MAX_QUOTES);
    record(outcome, { ...route, sourceCount: shown.length, ...extra });
    return memoryQueryResponse(
      { status: "supported", text: OPEN_RECALL_TEXT, sourceIds: shown.map((p) => p.entryId) },
      shown.map(toQuote),
    );
  };

  const work = async () => {
    const [safeQuestion, safeHint] = await Promise.all([
      redact(client, question, signal),
      hint ? redact(client, hint, signal) : Promise.resolve(""),
    ]);
    if (safeQuestion.length < 2) return memoryQueryResponse();
    // When the router declines, code routes the question from its wording:
    // the user is never told the journal couldn't be checked.
    const decided = await deps.route(safeQuestion, signal);
    signal.throwIfAborted();
    const route = decided ?? fallbackRoute(safeQuestion);
    const routed = (outcome: string, details: Record<string, unknown> = {}) =>
      record(outcome, { ...details, ...(decided ? {} : { routeFallback: true }) });
    if (route.operation === "conversation") {
      routed("conversation");
      return memoryQueryResponse({
        status: "conversation",
        text: "Continue the conversation normally.",
        sourceIds: [],
      });
    }

    const passages = await graph.evidence(safeHint || safeQuestion, signal, safeQuestion);
    signal.throwIfAborted();
    if (isOpenRecall(route)) {
      if (!passages.length) {
        routed("no_graph_match", route);
        return memoryQueryResponse();
      }
      return quotesAnswer(passages, route, "open_recall", decided ? {} : { routeFallback: true });
    }

    // EC-06: an exact question is answered from stored facts by code. No
    // model call after the router.
    const { entities, facts } = await graph.facts(signal);
    signal.throwIfAborted();
    const answer = answerFromFacts(safeQuestion, route, entities, facts);
    if (answer) {
      const text = await redact(client, answer.text, signal);
      if (text && text === answer.text) {
        routed("fact_answer", { ...route, status: answer.status, factCount: facts.length });
        return memoryQueryResponse(answer);
      }
    }
    // No stored fact fits: the user's own words, if any.
    if (passages.length) {
      return quotesAnswer(passages, route, "fact_fallback_quotes", decided ? {} : { routeFallback: true });
    }
    routed("no_graph_match", route);
    return memoryQueryResponse();
  };

  try {
    return await Promise.race([work(), expired]);
  } catch {
    if (!signal.aborted) record("workflow_unavailable");
    return memoryQueryResponse();
  } finally {
    clearTimeout(timer);
  }
}
