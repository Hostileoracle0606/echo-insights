/**
 * Extract phase for one scenario: each scripted turn goes through the same
 * steps the web app takes (src/lib/turn-state/web-adapter.ts), against the
 * local stack, as a throwaway user:
 *
 *   save the turn → reload the notebook snapshot → local lexical retrieval
 *   (retrieveMemory) → compileExtractionContext → the runtime request body →
 *   the extraction Lambda in-process (authorizer first, real Gemini) →
 *   mergeExtraction (follow-up dropped, as the web adapter does) →
 *   commit_notebook.
 *
 * Between sessions, scripted user actions call the RPCs the app's memory
 * controls call. Every state read goes back to the database, so a new session
 * is a client rebuilt from stored state only.
 */
import { randomUUID } from "node:crypto";

import { compileExtractionContext, DEFAULT_EXTRACTION_TOKEN_BUDGET } from "@/lib/extraction-context";
import type { ClientContext } from "@/lib/extract-graph";
import { retrieveMemory } from "@/lib/journal-memory";
import { DEFAULT_EXTRACTION_MODE, mergeExtraction } from "@/lib/journal-store";
import type { JournalState } from "@/lib/journal-types";

import { createSupabaseAuthorizer } from "../../infra/lambda/supabase-authorizer/core.mjs";
import { createExtractGraphHandler } from "../../infra/lambda/extract-graph/core.mjs";
import { gatewayInvoke, memoryClaimStore } from "../privacy/probes/lambdas.mjs";

export const EXTRACTOR_VERSION = "memory-eval/v1";
export const PROVIDER_HOSTS = ["generativelanguage.googleapis.com"];

type Fetch = ((input: string | URL, init?: RequestInit) => Promise<Response>) & {
  stopReason?: () => Error | null;
  pace?: () => Promise<void>;
};
type Action = { after_session: number; kind: "correct" | "remove" | "forget"; name: string; description?: string };
type Scenario = { id: string; sessions: Array<{ turns: string[] }>; actions?: Action[] };
type Env = { supabaseUrl: string; anonKey: string; user: { id: string; token: string }; geminiKey: string };

export class ExtractionFailed extends Error {
  constructor(readonly statusCode: number, readonly code: string) {
    super(`extraction returned ${statusCode} ${code}`);
    this.name = "ExtractionFailed";
  }
}

// A rejected commit loses the whole turn in the app too. Names the turn, the
// RPC's code and any relation endpoint that is neither an existing entity nor
// one arriving in the same change (commit_notebook's "relation endpoint not
// found" check), which the RPC's own message doesn't reach the caller with.
export class CommitRejected extends Error {
  constructor(
    readonly turnId: string,
    readonly code: string,
    readonly undeclaredEndpoints: string[],
  ) {
    super(`commit rejected ${code} at ${turnId}${undeclaredEndpoints.length ? ` (undeclared endpoints: ${undeclaredEndpoints.join(", ")})` : ""}`);
    this.name = "CommitRejected";
  }
}

// ── The runtime request context ─────────────────────────────────────────────
// Mirrors toRuntimeContext in src/lib/extraction-runtime-http.ts (PR #35, the
// web gateway client; not on this branch) and the Flutter client
// lib/services/extract_graph_service.dart: the compiled context, trimmed to
// the limits infra/lambda/extract-graph/core.mjs validates.
const ENTITY_TYPES = new Set(["person", "place", "organization", "project", "event", "activity", "concept", "emotion", "other"]);
const fits = (value: unknown, max: number): value is string =>
  typeof value === "string" && value.trim().length > 0 && value.length <= max;
const clip = (value: string, max: number) => (value.length <= max ? value : `${value.slice(0, max - 1).trimEnd()}…`);

export function toRuntimeContext(context: ClientContext) {
  const entities: Array<{ id: string; name: string; type: string; description?: string }> = [];
  const idByName = new Map<string, string>();
  for (const entity of context.existingEntities ?? []) {
    if (entities.length >= 20) break;
    const id = (entity as { id?: string }).id ?? entity.name;
    if (!fits(id, 160) || !fits(entity.name, 200)) continue;
    entities.push({
      id,
      name: entity.name,
      type: ENTITY_TYPES.has(entity.type) ? entity.type : "other",
      ...(entity.description ? { description: clip(entity.description, 1000) } : {}),
    });
    idByName.set(entity.name, id);
  }
  const relations: Array<{ id: string; source: string; target: string; label: string }> = [];
  for (const relation of context.existingRelations ?? []) {
    if (relations.length >= 30) break;
    const source = idByName.get(relation.source) ?? relation.source;
    const target = idByName.get(relation.target) ?? relation.target;
    if (!fits(relation.id, 320) || !fits(source, 160) || !fits(target, 160) || !fits(relation.label, 160)) continue;
    relations.push({ id: relation.id, source, target, label: relation.label });
  }
  const recentConversation = (context.recentConversation ?? [])
    .filter((turn) => (turn.role === "user" || turn.role === "assistant") && turn.text.trim())
    .slice(-4)
    .map((turn) => ({ role: turn.role, text: clip(turn.text, 4000) }));
  return { entities, relations, recentConversation };
}

// ── Resolving a scripted action's name to the entity the graph holds ────────
const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const containsWords = (hay: string, needle: string) => ` ${norm(hay)} `.includes(` ${norm(needle)} `);

export function resolveEntity(state: JournalState, name: string): { id: string; name: string } | null {
  const all = Object.values(state.entities);
  const exact = all.find((e) => norm(e.name) === norm(name));
  if (exact) return { id: exact.id, name: exact.name };
  const close = all
    .filter((e) => containsWords(e.name, name) || containsWords(name, e.name))
    .sort((a, b) => a.name.length - b.name.length || a.id.localeCompare(b.id));
  return close[0] ? { id: close[0].id, name: close[0].name } : null;
}

const ACTION_RPC = {
  correct: (id: string, a: Action) => ["edit_entity_description", { p_entity_id: id, p_text: a.description }],
  remove: (id: string) => ["remove_entity", { p_entity_id: id }],
  forget: (id: string) => ["forget_entity", { p_entity_id: id }],
} as const;

export type TurnReport = {
  turnId: string;
  session: number;
  text: string;
  patch: { entities?: Array<{ name: string; type?: string; description?: string }>; relations?: Array<{ source: string; label: string; target: string }> } | null;
  extractionStatus: number;
  commit: { status: string; code: string | null } | null;
  before: JournalState;
  after: JournalState;
  latencyMs: { extraction: number; commit: number };
};

export async function replayScenario({
  scenario,
  env,
  fetchImpl,
  takeSnapshot,
  now = () => new Date(),
  onTurn,
}: {
  scenario: Scenario;
  env: Env;
  fetchImpl: Fetch;
  takeSnapshot: (notebookId: string) => Promise<unknown>;
  now?: () => Date;
  /** Optional per-turn report for the stage tracks (eval/stages); unused by eval/memory. */
  onTurn?: (turn: TurnReport) => Promise<void> | void;
}) {
  let providerCalls = 0;
  const counted: Fetch = async (input, init) => {
    if (PROVIDER_HOSTS.includes(new URL(String(input)).hostname)) providerCalls += 1;
    return fetchImpl(input, init);
  };
  const stopIfSpent = () => {
    const stop = fetchImpl.stopReason?.();
    if (stop) throw stop;
  };

  const userHeaders = {
    apikey: env.anonKey,
    authorization: `Bearer ${env.user.token}`,
    "content-type": "application/json",
  };
  async function rest(path: string, init: { method?: string; body?: unknown; prefer?: string } = {}) {
    const response = await fetchImpl(`${env.supabaseUrl}/rest/v1/${path}`, {
      method: init.method ?? "POST",
      headers: { ...userHeaders, ...(init.prefer ? { prefer: init.prefer } : {}) },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      signal: AbortSignal.timeout(15_000),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${path.split("?")[0]} → ${response.status} ${text.slice(0, 200)}`);
    return text ? JSON.parse(text) : null;
  }
  const loadSnapshot = async (): Promise<{ revision: number; state: JournalState }> => {
    const snap = await rest("rpc/get_notebook_snapshot", { body: { p_notebook_id: notebookId } });
    const raw = snap.state ?? {};
    return {
      revision: Number(snap.revision),
      state: {
        entries: raw.entries ?? [],
        entities: raw.entities ?? {},
        relations: raw.relations ?? {},
        followUps: raw.followUps ?? [],
        askedQuestions: raw.askedQuestions ?? [],
      },
    };
  };

  const [notebook] = await rest("notebooks", {
    prefer: "return=representation",
    body: { user_id: env.user.id, title: `memory eval: ${scenario.id}`, started_at: now().toISOString() },
  });
  const notebookId: string = notebook.id;

  const deps = {
    supabaseUrl: env.supabaseUrl,
    publishableKey: env.anonKey,
    fetchImpl: counted,
    getPermanentCredential: async () => env.geminiKey,
  };
  const authorize = createSupabaseAuthorizer(deps);
  const extract = createExtractGraphHandler({ ...deps, ...memoryClaimStore(), sleep: async () => {} });

  const actions: Array<Action & { entityId: string | null; outcome: string }> = [];
  const lostTurns: Array<{ turnId: string; reason: string; undeclaredEndpoints: string[]; patch?: unknown }> = [];
  let turns = 0;
  for (const [index, session] of scenario.sessions.entries()) {
    const sessionNumber = index + 1;
    const sessionTurns: Array<{ role: "user"; text: string }> = [];
    for (const [t, text] of session.turns.entries()) {
      const turnId = `${scenario.id}-s${sessionNumber}-t${t + 1}`;
      // As lib/services/transcript_store.dart saves a turn: insert, ignore a
      // duplicate, owner from the column default.
      await rest("conversation_turns?on_conflict=notebook_id,turn_id", {
        prefer: "resolution=ignore-duplicates",
        body: { notebook_id: notebookId, turn_id: turnId, speaker: "user", text,
          spoken_at: now().toISOString(), input: "typed" },
      });
      const { revision, state } = await loadSnapshot();
      const retrieval = await retrieveMemory(state, text, notebookId);
      const compiled = compileExtractionContext({
        transcript: text,
        state,
        retrieval,
        recentTurns: sessionTurns,
        budget: DEFAULT_EXTRACTION_TOKEN_BUDGET,
      });
      const body = {
        turnId,
        extractorVersion: EXTRACTOR_VERSION,
        text,
        mode: DEFAULT_EXTRACTION_MODE,
        context: toRuntimeContext(compiled.clientContext),
      };
      await fetchImpl.pace?.();
      const extractionStarted = Date.now();
      const response = await gatewayInvoke({
        authorize,
        handler: extract,
        event: {
          headers: { authorization: `Bearer ${env.user.token}` },
          pathParameters: { notebookId },
          requestContext: {},
          body: JSON.stringify(body),
        },
      });
      const extractionMs = Date.now() - extractionStarted;
      stopIfSpent();
      const parsed = JSON.parse(response.body || "{}");
      // A failed extraction or a rejected commit loses this turn's memory in
      // the app, which carries on with the conversation; so does the replay,
      // recording the loss. (The turn itself was said, so it stays in the
      // recent conversation.) Quota stops are the only thing that aborts.
      turns += 1;
      sessionTurns.push({ role: "user", text });
      if (response.statusCode !== 200) {
        lostTurns.push({ turnId, reason: `extraction ${response.statusCode} ${parsed.code ?? "unknown"}`, undeclaredEndpoints: [] });
        await onTurn?.({ turnId, session: sessionNumber, text, patch: null, extractionStatus: response.statusCode,
          commit: null, before: state, after: state, latencyMs: { extraction: extractionMs, commit: 0 } });
        continue;
      }
      // The web adapter drops the extractor's follow-up: Gemini Live owns dialogue.
      const { change } = mergeExtraction(state, text, { ...parsed.patch, followUp: undefined });
      const commitStarted = Date.now();
      const outcome = await rest("rpc/commit_notebook", {
        body: { p_notebook_id: notebookId, p_expected_revision: revision, p_request_id: randomUUID(), p_change: change },
      });
      const commitMs = Date.now() - commitStarted;
      if (outcome?.status !== "committed") {
        const known = new Set([...Object.keys(state.entities), ...change.entities.map((e) => e.id)]);
        const undeclared = change.relations.flatMap((r) => [r.source, r.target]).filter((id) => !known.has(id));
        lostTurns.push({ turnId, reason: `commit ${outcome?.code ?? outcome?.status ?? "unknown"}`,
          undeclaredEndpoints: [...new Set(undeclared)], patch: parsed.patch });
      }
      if (onTurn) {
        const after = outcome?.status === "committed" ? (await loadSnapshot()).state : state;
        await onTurn({ turnId, session: sessionNumber, text, patch: parsed.patch, extractionStatus: 200,
          commit: { status: outcome?.status ?? "unknown", code: outcome?.code ?? null }, before: state, after,
          latencyMs: { extraction: extractionMs, commit: commitMs } });
      }
    }
    for (const action of (scenario.actions ?? []).filter((a) => a.after_session === sessionNumber)) {
      const { state } = await loadSnapshot();
      const target = resolveEntity(state, action.name);
      if (!target) {
        actions.push({ ...action, entityId: null, outcome: "not_extracted" });
        continue;
      }
      const [fn, args] = ACTION_RPC[action.kind](target.id, action);
      try {
        await rest(`rpc/${fn}`, { body: args });
        actions.push({ ...action, entityId: target.id, outcome: "applied" });
      } catch (error) {
        actions.push({ ...action, entityId: target.id, outcome: `failed: ${(error as Error).message.slice(0, 120)}` });
      }
    }
  }

  const snapshot = await takeSnapshot(notebookId);
  return {
    snapshot,
    notebookId,
    meta: { scenario: scenario.id, extractorVersion: EXTRACTOR_VERSION, mode: DEFAULT_EXTRACTION_MODE,
      model: "gemini-2.5-flash", turns, providerCalls, actions, lostTurns, extractedAt: now().toISOString() },
  };
}
