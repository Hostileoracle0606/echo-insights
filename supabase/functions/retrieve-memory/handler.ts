import type { DbClient } from "../_shared/db-client.ts";
import { retrieve } from "../_shared/graphloop/retrieve.ts";
import { SearchIndex } from "../_shared/graphloop/search-index.ts";
import { buildCommunities } from "../_shared/graphloop/communities.ts";
import type { Entity, EntityType, GraphState, Relation } from "../_shared/graphloop/types.ts";
import type { Embedder } from "../_shared/embedder.ts";
import {
  retrieveMemoryResponseV1,
  retrieveMemoryResponseV2,
} from "../_shared/retrieve-memory-contract.ts";
import { buildContext } from "./context.ts";
import { graphEvidence } from "./graph-evidence.ts";
import { isMemoryFactHistory, type MemoryFact } from "../_shared/memory-fact-contract.ts";
import { selectRelevant } from "./select.ts";
import { candidateDocument, candidateIds, selectReranked } from "../_shared/reranker/core.ts";
import { normalizeName } from "../_shared/graphloop/noise.ts";
import { loadQuotes } from "./quotes.ts";
import { runMemoryQuery, type MemoryQueryDeps } from "./memory-query.ts";
import { memoryQueryResponse } from "./memory-query-types.ts";
import type { MemoryReranker } from "./memory-reranker.ts";
import type { MemoryRerankTrace } from "./graph-evidence.ts";

// The handler takes its clients, embedder and logger as dependencies so it
// can be tested without a Supabase stack; index.ts wires the real ones.

export type { DbClient };

export interface RetrieveMemoryDeps {
  /** Anon-key client carrying the caller's JWT: every read through it is RLS-scoped. */
  userClient(authHeader: string): DbClient;
  /** Service-role client, used only for the embedding match. */
  adminClient(): DbClient;
  /** Throwing here (no Supabase.ai locally) just disables semantic seeds. */
  embedder(): Embedder;
  log(fields: Record<string, unknown>): void;
  /** Optional while the routed voice workflow is evaluated. */
  memoryQuery?: MemoryQueryDeps;
  /** Optional Lumen-only stage-two ranker. Disabled unless an endpoint is configured. */
  reranker?: MemoryReranker;
  rerankerCandidateCount?: number;
  rerankerBudgetMs?: number;
  /** Private test/debug hook. It receives IDs and features, never memory text. */
  rerankDebug?: (trace: MemoryRerankTrace) => void;
  /** Enabled only by the isolated local evaluation entrypoint. */
  evalSelectionArms?: boolean;
  /**
   * The reranker on the default live path (v2 user scope): "shadow" scores every
   * pool after the response and logs what would change; "on" seeds from its order.
   * Absent = current search only, even when `reranker` serves the routed path.
   */
  rerankMode?: "shadow" | "on";
  /** Runs work after the response (EdgeRuntime.waitUntil): shadow scoring never delays the user. */
  waitUntil?: (work: Promise<unknown>) => void;
}

/**
 * Re-seeds current search's selection from the reranker's order, as it was
 * evaluated (ml/embedding/validation/rerank.ts on feat/reranker): candidates
 * are the eligible vector seeds plus name matches, the seed count is current
 * search's, and the production selector still owns neighbour expansion. The
 * seeds go in as `semantic` priorities, exactly as evaluated. Logs are content-free.
 */
async function rerankSelection(
  reranker: MemoryReranker,
  mode: "shadow" | "on",
  g: GraphState,
  query: string,
  extraSeeds: Map<string, number> | undefined,
  baseline: ReturnType<typeof selectRelevant>,
): Promise<{ result: ReturnType<typeof selectRelevant>; log: Record<string, unknown> }> {
  const candidates = candidateIds(g.entities, query, [...(extraSeeds?.keys() ?? [])], normalizeName);
  if (!candidates.length || !baseline.seeds.length) return { result: baseline, log: { rerank: "skipped" } };
  const started = Date.now();
  try {
    const scores = await reranker.rank(query, candidates.map((id) => ({ id, text: candidateDocument(g, id) })),
      new AbortController().signal);
    const logits = candidates.map((id) => scores.get(id) ?? Number.NaN);
    const reranked = selectReranked(candidates, logits, baseline.seeds.length, (priority) => selectRelevant(g, "", priority));
    const changed = reranked.seeds.filter((id) => !baseline.seeds.includes(id)).length;
    return {
      result: mode === "on" ? reranked : baseline,
      log: { rerank: mode, rerankMs: Date.now() - started, rerankCandidates: candidates.length, rerankSeedsChanged: changed },
    };
  } catch {
    return { result: baseline, log: { rerank: "error", rerankMs: Date.now() - started } };
  }
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const MAX_BODY_BYTES = 1_000_000;
// LM-46 request-field caps. Queries are a spoken phrase or two; ids are uuids.
const MAX_QUERY_CHARS = 2000;
const MAX_ID_CHARS = 100;
/** `limit` is not read today; if a client sends one it must be a sane integer. */
const MAX_LIMIT = 50;
// Client-sent graph caps (notebook scope only; user scope never reads body.state).
const MAX_ENTITIES = 2000;
const MAX_RELATIONS = 4000;
const MAX_ENTRIES = 2000;
/** get_user_graph clamps p_limit to 2000 itself. */
const USER_GRAPH_LIMIT = 2000;
const SEED_LIMIT = 12;
const MIN_SEED_SCORE = 0.7;

type Scope = "notebook" | "user";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

/**
 * Field types and sizes of the request body. Never echoes a value back: the
 * caller gets one generic message whichever field was wrong. `scope` has its
 * own check below because it predates this one.
 */
export function validRequestShape(body: unknown): boolean {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return false;
  const b = body as Record<string, unknown>;
  if (b.version === 3 && (b.scope !== "user" || typeof b.question !== "string" ||
    b.question.length > MAX_QUERY_CHARS || b.question.trim().length < 2)) return false;
  if (
    b.query !== undefined &&
    b.query !== null &&
    (typeof b.query !== "string" || b.query.length > MAX_QUERY_CHARS)
  )
    return false;
  if (
    b.notebookId !== undefined &&
    b.notebookId !== null &&
    (typeof b.notebookId !== "string" || b.notebookId.length > MAX_ID_CHARS)
  )
    return false;
  if (
    b.limit !== undefined &&
    (typeof b.limit !== "number" ||
      !Number.isInteger(b.limit) ||
      b.limit < 1 ||
      b.limit > MAX_LIMIT)
  )
    return false;
  if (b.state !== undefined && b.state !== null) {
    if (typeof b.state !== "object" || Array.isArray(b.state)) return false;
    const s = b.state as Record<string, unknown>;
    for (const key of ["entities", "relations"]) {
      const v = s[key];
      if (v !== undefined && v !== null && (typeof v !== "object" || Array.isArray(v)))
        return false;
    }
    if (s.entries !== undefined && s.entries !== null && !Array.isArray(s.entries)) return false;
  }
  return true;
}

async function queryHash(q: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(q));
  return [...new Uint8Array(digest)]
    .slice(0, 4)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Semantic seeds (hybrid). Service-role, downstream of ownership + rate.
 * Fail-closed: any failure → undefined → lexical-only behavior.
 */
async function semanticSeeds(
  deps: RetrieveMemoryDeps,
  query: string,
  match: (vector: string, model: string) => { fn: string; args: Record<string, unknown> },
): Promise<Map<string, number> | undefined> {
  try {
    const embedder = deps.embedder();
    const [qvec] = await embedder.embed([query]);
    // vector literal — reliable across PostgREST
    const { fn, args } = match(`[${qvec.join(",")}]`, embedder.modelId);
    const { data: matches } = await deps.adminClient().rpc(fn, args);
    if (!Array.isArray(matches)) return undefined;
    return new Map(
      (matches as { entity_id: string; score: number }[])
        .filter((m) => m.score >= MIN_SEED_SCORE)
        .map((m) => [m.entity_id, m.score]),
    );
  } catch {
    return undefined;
  }
}

/** get_user_graph's camelCase JSON → graphloop GraphState. */
export function userGraphToState(data: unknown): GraphState {
  const raw = (data ?? {}) as { entities?: unknown; relations?: unknown };
  const entities: Record<string, Entity> = {};
  for (const e of Array.isArray(raw.entities) ? raw.entities : []) {
    if (!e || typeof e.id !== "string" || typeof e.name !== "string") continue;
    entities[e.id] = {
      id: e.id,
      name: e.name,
      type: (e.type ?? "other") as EntityType,
      ...(typeof e.description === "string" ? { description: e.description } : {}),
      metadata: {},
      mentions: typeof e.mentions === "number" ? e.mentions : 1,
      firstSeen: String(e.firstSeen ?? ""),
      lastSeen: String(e.lastSeen ?? ""),
    };
  }
  const relations: Record<string, Relation> = {};
  for (const r of Array.isArray(raw.relations) ? raw.relations : []) {
    if (
      !r ||
      typeof r.id !== "string" ||
      typeof r.source !== "string" ||
      typeof r.target !== "string"
    ) {
      continue;
    }
    // get_user_graph returns active relations only and no timestamps;
    // retrieval reads neither createdAt nor metadata.
    relations[r.id] = {
      id: r.id,
      source: r.source,
      target: r.target,
      label: String(r.label ?? ""),
      metadata: {},
      createdAt: "",
    };
  }
  return { entities, relations, entries: [] };
}

async function rank(g: GraphState, query: string, extraSeeds: Map<string, number> | undefined) {
  const index = new SearchIndex();
  await index.sync(Object.values(g.entities));
  const communities = buildCommunities(g);
  return await retrieve(g, query, { mode: "lexical" }, { index, communities, extraSeeds });
}

export function createHandler(deps: RetrieveMemoryDeps): (req: Request) => Promise<Response> {
  const logTelemetry = deps.log;

  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") {
      const headers: Record<string, string> = { ...corsHeaders };
      if (deps.evalSelectionArms) {
        headers["Access-Control-Allow-Headers"] += ", x-lumen-eval-selection-arm, x-lumen-eval-trial-id";
        headers["Access-Control-Expose-Headers"] = "x-lumen-eval-trace";
      }
      return new Response(null, { headers });
    }
    const startedAt = Date.now();
    let scope: Scope = "notebook";
    const armHeader = req.headers.get("x-lumen-eval-selection-arm");
    const evalArm = deps.evalSelectionArms &&
        (armHeader === "baseline" || armHeader === "dense" || armHeader === "dense-pairwise")
      ? armHeader
      : undefined;
    const rawTrialId = req.headers.get("x-lumen-eval-trial-id") ?? "";
    const evalTrialId = /^[A-Za-z0-9_-]{1,64}$/.test(rawTrialId) ? rawTrialId : undefined;
    let evalTrace: MemoryRerankTrace | undefined;
    try {
      const raw = await req.text();
      if (raw.length > MAX_BODY_BYTES) return json(413, { error: "body too large" });

      const authHeader = req.headers.get("Authorization");
      if (!authHeader) return json(401, { error: "missing authorization" });
      const supa = deps.userClient(authHeader);
      const {
        data: { user },
        error: userErr,
      } = await supa.auth.getUser();
      if (userErr || !user) return json(401, { error: "invalid session" });

      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        return json(400, { error: "invalid request" });
      }
      if (!validRequestShape(parsed)) return json(400, { error: "invalid request" });
      const body = parsed as {
        query?: string;
        question?: string;
        version?: number;
        notebookId?: string;
        scope?: unknown;
        state?: {
          entities?: Record<string, unknown>;
          relations?: Record<string, unknown>;
          entries?: unknown[];
        };
      };

      // Absent scope = the original notebook-scope v1 contract (old clients).
      if (body.scope !== undefined && body.scope !== "notebook" && body.scope !== "user") {
        return json(400, { error: "invalid scope" });
      }
      scope = body.scope === "user" ? "user" : "notebook";

      // Both scopes require the open conversation: it is what the rate limit
      // and the "other notebooks only" quote rule are keyed on.
      const notebookId = body.notebookId;
      if (!notebookId) return json(400, { error: "notebookId required" });
      const { data: nb, error: nbErr } = await supa
        .from("notebooks")
        .select("id")
        .eq("id", notebookId)
        .single();
      if (nbErr || !nb) return json(404, { error: "notebook not found" });

      // Durable, per-user AND per-notebook rate limit, enforced server-side so a
      // direct JWT caller cannot bypass it the way the Flutter guardrails allow.
      // Window + limits live in the DB function; the client controls nothing, and
      // the function verifies notebook ownership itself.
      const { data: allowed, error: rateErr } = await supa.rpc("bump_retrieve_rate", {
        p_notebook_id: notebookId,
      });
      if (rateErr) {
        logTelemetry({
          ok: false,
          scope,
          error: "rate_check_failed",
          latencyMs: Date.now() - startedAt,
        });
        return json(500, { error: "rate check failed" });
      }
      if (allowed === false) {
        logTelemetry({
          ok: false,
          scope,
          error: "rate_limited",
          latencyMs: Date.now() - startedAt,
        });
        return json(429, { error: "rate limit exceeded" });
      }

      const query = (body.query ?? "").trim();

      if (body.version === 3) {
        if (!deps.memoryQuery) return json(200, memoryQueryResponse());
        // Evidence comes from the graph only: the entities matching the
        // question and their linked entries (graph-evidence.ts), and the
        // facts stored for those entities (EC-06).
        let selected: { id: string; name: string }[] = [];
        const graphSource = {
          evidence: async (graphQuery: string, signal: AbortSignal, rerankQuery = graphQuery) => {
            const [graph, seeds] = await Promise.all([
              supa.rpc("get_user_graph", { p_types: null, p_limit: USER_GRAPH_LIMIT }),
              semanticSeeds(deps, graphQuery, (vector, model) => ({
                fn: "match_user_entity_embeddings",
                args: { p_user_id: user.id, p_query: vector, p_limit: evalArm === "dense" || evalArm === "dense-pairwise" ? 20 : SEED_LIMIT, p_model: model },
              })),
            ]);
            signal.throwIfAborted();
            if (graph.error) return [];
            const g = userGraphToState(graph.data);
            if (!Object.keys(g.entities).length) return [];
            const found = await graphEvidence(supa, g, graphQuery, seeds, signal, {
              reranker: deps.reranker,
              rerankQuery,
              candidateCount: evalArm === "dense-pairwise" ? 20 : deps.rerankerCandidateCount,
              budgetMs: deps.rerankerBudgetMs,
              evalArm,
              evalTrialId,
              debug: evalArm ? (trace) => { evalTrace = trace; } : deps.rerankDebug,
              // Facts must keep using the same baseline candidate set as
              // before reranking; only passage selection is reranked.
              onBaselineEntityIds: (ids) => {
                selected = ids.map((id) => ({ id, name: g.entities[id]?.name ?? id }));
              },
            });
            return found.passages;
          },
          facts: async (signal: AbortSignal) => {
            if (!selected.length) return { entities: [], facts: [] };
            const { data, error } = await supa.rpc("get_entity_fact_history", {
              p_entity_ids: selected.map((e) => e.id),
            });
            signal.throwIfAborted();
            if (error || !isMemoryFactHistory({ facts: data })) {
              return { entities: selected, facts: [] };
            }
            return { entities: selected, facts: data as MemoryFact[] };
          },
        };
        const response = json(
          200,
          await runMemoryQuery(
            deps.memoryQuery,
            supa,
            body.question!.trim(),
            query,
            startedAt,
            graphSource,
            logTelemetry,
          ),
        );
        if (evalArm && evalTrace) {
          const trace = {
            v: 1,
            arm: evalTrace.arm,
            trial: evalTrace.trialId,
            candidates: evalTrace.candidates.map(({ id, hash, score }) => [id, hash, score]),
            baseline: evalTrace.baselineIds,
            selected: evalTrace.rerankedIds,
            baselineEntities: evalTrace.baselineEntityHashes,
            returnedEntities: evalTrace.selectedEntityHashes,
            baselineSeeds: evalTrace.baselineSeedHashes,
            selectedSeeds: evalTrace.selectedSeedHashes,
            retainedEntries: evalTrace.retainedEntryIds,
            fallback: evalTrace.fallback,
            elapsedMs: evalTrace.durationMs,
          };
          const bytes = new TextEncoder().encode(JSON.stringify(trace));
          let binary = "";
          for (const byte of bytes) binary += String.fromCharCode(byte);
          response.headers.set("x-lumen-eval-trace", btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, ""));
          response.headers.set("Access-Control-Expose-Headers", "x-lumen-eval-trace");
        }
        return response;
      }

      if (scope === "user") {
        if (!query) return json(200, retrieveMemoryResponseV2("", [], []));
        // body.state is ignored: the graph is the user's merged memory, read
        // with THEIR token so RLS limits it to them. Only the embedding match
        // runs as the service role, with the user id proven by getUser above.
        const [graph, extraSeeds] = await Promise.all([
          supa.rpc("get_user_graph", { p_types: null, p_limit: USER_GRAPH_LIMIT }),
          semanticSeeds(deps, query, (vector, model) => ({
            fn: "match_user_entity_embeddings",
            args: { p_user_id: user.id, p_query: vector, p_limit: SEED_LIMIT, p_model: model },
          })),
        ]);
        if (graph.error) {
          logTelemetry({
            ok: false,
            scope,
            error: "user_graph_failed",
            latencyMs: Date.now() - startedAt,
          });
          return json(500, { error: "retrieve failed" });
        }
        const g = userGraphToState(graph.data);
        if (Object.keys(g.entities).length === 0) {
          return json(200, retrieveMemoryResponseV2("", [], []));
        }
        // The live tool: only what is close in meaning to the query (select.ts).
        const baseline = selectRelevant(g, query, extraSeeds);
        let result = baseline;
        let rerankLog: Record<string, unknown> = {};
        if (deps.reranker && deps.rerankMode === "on") {
          ({ result, log: rerankLog } = await rerankSelection(deps.reranker, "on", g, query, extraSeeds, baseline));
        } else if (deps.reranker && deps.rerankMode === "shadow") {
          // Shadow: same scoring, its own content-free log line, never in the response path.
          const shadow = rerankSelection(deps.reranker, "shadow", g, query, extraSeeds, baseline)
            .then(({ log }) => logTelemetry({ ok: true, scope, ...log }));
          if (deps.waitUntil) deps.waitUntil(shadow);
          else await shadow;
        }
        const context = buildContext(result);
        const entityIds = result.entities.map((entity) => entity.id);
        const quotes = entityIds.length === 0 ? [] : await loadQuotes(supa, entityIds, notebookId);
        logTelemetry({
          ok: true,
          scope,
          ...rerankLog,
          entityCount: result.entities.length,
          relationCount: result.relations.length,
          seedCount: result.seeds.length,
          quoteCount: quotes.length,
          emptyContext: context.length === 0,
          latencyMs: Date.now() - startedAt,
          qHash: await queryHash(query),
        });
        return json(200, retrieveMemoryResponseV2(context, entityIds, quotes));
      }

      const entities = body.state?.entities ?? {};
      const relations = body.state?.relations ?? {};
      const entries = body.state?.entries ?? [];
      if (
        Object.keys(entities).length > MAX_ENTITIES ||
        Object.keys(relations).length > MAX_RELATIONS ||
        entries.length > MAX_ENTRIES
      ) {
        return json(413, { error: "graph too large" });
      }
      if (!query || Object.keys(entities).length === 0) {
        return json(200, retrieveMemoryResponseV1("", []));
      }

      const extraSeeds = await semanticSeeds(deps, query, (vector, model) => ({
        fn: "match_entity_embeddings",
        args: { p_notebook_id: notebookId, p_query: vector, p_limit: SEED_LIMIT, p_model: model },
      }));
      const g = { entities, relations, entries } as unknown as GraphState;
      const result = await rank(g, query, extraSeeds);
      const context = buildContext(result);
      logTelemetry({
        ok: true,
        scope,
        entityCount: result.entities.length,
        relationCount: result.relations.length,
        seedCount: result.seeds.length,
        quoteCount: 0,
        emptyContext: context.length === 0,
        latencyMs: Date.now() - startedAt,
        qHash: await queryHash(query),
      });
      return json(
        200,
        retrieveMemoryResponseV1(
          context,
          result.entities.map((entity) => entity.id),
        ),
      );
    } catch (e) {
      // Never log the request body, query, context or quotes. Counts / error name only.
      logTelemetry({
        ok: false,
        scope,
        error: e instanceof Error ? e.name : "unknown",
        latencyMs: Date.now() - startedAt,
      });
      return json(500, { error: "retrieve failed" });
    }
  };
}
