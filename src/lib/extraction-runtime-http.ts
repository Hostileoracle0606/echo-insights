/**
 * Web client for the Notebook Runtime's graph-extraction route:
 * `POST /v1/notebooks/{notebookId}/extractions`, handled by
 * `infra/lambda/extract-graph`.
 *
 * The Lambda holds the Gemini credential in Secrets Manager, checks the
 * caller's Supabase session and notebook ownership, redacts forgotten names,
 * and caches the result per (user, notebook, turn, extractor version). The
 * browser only ever sends the user's own access token, so no provider key is
 * shipped in the client bundle. The Flutter app's
 * `lib/services/extract_graph_service.dart` speaks the same contract.
 */

import {
  emptyExtractionResult,
  parseExtractionPatch,
  type ClientContext,
  type ExtractGraphResult,
} from "./extract-graph";
import type { ExtractionMode } from "./journal-types";

// Limits enforced by the runtime's request validation (core.mjs). A request
// over any of them is rejected outright, so the client trims to fit.
const MAX_ENTITIES = 20;
const MAX_RELATIONS = 30;
const MAX_TURNS = 4;
const MAX_ENTITY_ID = 160;
const MAX_ENTITY_NAME = 200;
const MAX_DESCRIPTION = 1000;
const MAX_RELATION_ID = 320;
const MAX_RELATION_END = 160;
const MAX_LABEL = 160;
const MAX_TURN_TEXT = 4000;
const MAX_FOLLOW_UP = 1000;
const MAX_TEXT = 50000;
/** The runtime rejects shorter turns; there is nothing to extract from them. */
export const MIN_EXTRACTION_TEXT_LENGTH = 6;

const ENTITY_TYPES = new Set([
  "person",
  "place",
  "organization",
  "project",
  "event",
  "activity",
  "concept",
  "emotion",
  "other",
]);

const MAX_IN_PROGRESS_POLLS = 40;
const MAX_IN_PROGRESS_DELAY_MS = 2000;
const MAX_RETRIES = 2;

export interface RuntimeExtractionContext {
  entities: Array<{ id: string; name: string; type: string; description?: string }>;
  relations: Array<{ id: string; source: string; target: string; label: string }>;
  recentConversation: Array<{ role: "user" | "assistant"; text: string }>;
  answeringFollowUp?: { question: string; reason: string };
}

export interface ExtractionRequest {
  notebookId: string;
  turnId: string;
  extractorVersion: string;
  text: string;
  mode: ExtractionMode;
  context: ClientContext;
}

export interface ExtractionRuntime {
  extract(request: ExtractionRequest, signal?: AbortSignal): Promise<ExtractGraphResult>;
}

type ExtractionRuntimeOptions = {
  baseUrl: string;
  getAccessToken: () => Promise<string | null>;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
};

const fits = (value: unknown, max: number): value is string =>
  typeof value === "string" && value.trim().length > 0 && value.length <= max;

const clip = (value: string, max: number): string =>
  value.length <= max ? value : `${value.slice(0, max - 1).trimEnd()}…`;

/**
 * Maps the web app's compiled context onto the runtime's request shape.
 * Anything the runtime would reject is trimmed or left out rather than
 * failing the whole turn.
 */
export function toRuntimeContext(context: ClientContext): RuntimeExtractionContext {
  const entities: RuntimeExtractionContext["entities"] = [];
  const idByName = new Map<string, string>();
  for (const entity of context.existingEntities ?? []) {
    if (entities.length >= MAX_ENTITIES) break;
    const id = entity.id ?? entity.name;
    if (!fits(id, MAX_ENTITY_ID) || !fits(entity.name, MAX_ENTITY_NAME)) continue;
    entities.push({
      id,
      name: entity.name,
      type: ENTITY_TYPES.has(entity.type) ? entity.type : "other",
      ...(entity.description ? { description: clip(entity.description, MAX_DESCRIPTION) } : {}),
    });
    idByName.set(entity.name, id);
  }

  // The compiled context names relation endpoints; the runtime resolves
  // endpoints by entity id and falls back to the raw value.
  const relations: RuntimeExtractionContext["relations"] = [];
  for (const relation of context.existingRelations ?? []) {
    if (relations.length >= MAX_RELATIONS) break;
    const source = idByName.get(relation.source) ?? relation.source;
    const target = idByName.get(relation.target) ?? relation.target;
    if (
      !fits(relation.id, MAX_RELATION_ID) ||
      !fits(source, MAX_RELATION_END) ||
      !fits(target, MAX_RELATION_END) ||
      !fits(relation.label, MAX_LABEL)
    ) {
      continue;
    }
    relations.push({ id: relation.id, source, target, label: relation.label });
  }

  const recentConversation = (context.recentConversation ?? [])
    .filter((turn) => (turn.role === "user" || turn.role === "assistant") && turn.text.trim())
    .slice(-MAX_TURNS)
    .map((turn) => ({ role: turn.role, text: clip(turn.text, MAX_TURN_TEXT) }));

  const followUp = context.answeringFollowUp;
  const answeringFollowUp =
    followUp && followUp.question.trim()
      ? {
          question: clip(followUp.question, MAX_FOLLOW_UP),
          reason: clip(followUp.reason ?? "", MAX_FOLLOW_UP),
        }
      : undefined;

  return {
    entities,
    relations,
    recentConversation,
    ...(answeringFollowUp ? { answeringFollowUp } : {}),
  };
}

function abortError(): DOMException {
  return new DOMException("Aborted", "AbortError");
}

function abortableSleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError());
      return;
    }
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        reject(abortError());
      },
      { once: true },
    );
  });
}

async function readJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

export function createExtractionRuntime({
  baseUrl,
  getAccessToken,
  fetchImpl = fetch,
  sleep = abortableSleep,
}: ExtractionRuntimeOptions): ExtractionRuntime {
  const normalizedBaseUrl = baseUrl.replace(/\/$/, "");

  return {
    async extract(request, signal) {
      const text = request.text.trim();
      if (text.length < MIN_EXTRACTION_TEXT_LENGTH) return emptyExtractionResult();

      const accessToken = await getAccessToken();
      if (!accessToken) throw new Error("A signed-in session is required");

      const url = `${normalizedBaseUrl}/v1/notebooks/${encodeURIComponent(request.notebookId)}/extractions`;
      // The runtime caches by turn and extractor version and refuses the same
      // key with a different mode, so the mode is part of the version.
      const body = JSON.stringify({
        turnId: request.turnId,
        extractorVersion: `${request.extractorVersion}#${request.mode}`,
        text: clip(text, MAX_TEXT),
        mode: request.mode,
        context: toRuntimeContext(request.context),
      });

      let inProgressPolls = 0;
      for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
        let response: Response;
        try {
          response = await fetchImpl(url, {
            method: "POST",
            headers: {
              accept: "application/json",
              authorization: `Bearer ${accessToken}`,
              "content-type": "application/json",
            },
            body,
            signal,
          });
        } catch (error) {
          if (signal?.aborted || attempt === MAX_RETRIES) throw error;
          await sleep(500 * 2 ** attempt, signal);
          continue;
        }

        if (response.status === 401 || response.status === 403) {
          throw new Error("The signed-in session is no longer valid");
        }

        if (response.status === 409) {
          const outcome = (await readJson(response)) as Record<string, unknown> | null;
          if (outcome?.code === "inProgress" && inProgressPolls < MAX_IN_PROGRESS_POLLS) {
            const requested = outcome.retryAfterMs;
            const delayMs =
              typeof requested === "number"
                ? Math.min(Math.max(requested, 0), MAX_IN_PROGRESS_DELAY_MS)
                : 500;
            inProgressPolls += 1;
            await sleep(delayMs, signal);
            // Waiting on another request for the same turn is not a failure,
            // so it does not spend the retry budget.
            attempt -= 1;
            continue;
          }
          throw new Error(`Graph extraction was refused (${String(outcome?.code ?? 409)})`);
        }

        if (response.status === 400) {
          // A request the runtime cannot accept will not improve on retry.
          // Skip this turn rather than break the graph.
          console.error("[extractGraph] runtime rejected the request", { status: 400 });
          return emptyExtractionResult();
        }

        if ((response.status === 429 || response.status >= 500) && attempt < MAX_RETRIES) {
          await readJson(response);
          await sleep(500 * 2 ** attempt, signal);
          continue;
        }

        if (response.status === 429) {
          throw new Error("Rate limit exceeded. Please wait a moment.");
        }
        if (response.status === 502) {
          // The model returned no usable patch, even after retries.
          return emptyExtractionResult();
        }
        if (!response.ok) {
          throw new Error(`Graph extraction failed (${response.status})`);
        }

        const decoded = (await readJson(response)) as { patch?: unknown } | null;
        const result = parseExtractionPatch(decoded?.patch);
        if (!result) throw new Error("The extraction runtime returned an invalid patch");
        return result;
      }
      return emptyExtractionResult();
    },
  };
}
