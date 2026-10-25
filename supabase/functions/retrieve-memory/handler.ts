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
import { loadQuotes } from "./quotes.ts";

// The handler takes its clients, embedder and logger as dependencies so it
// can be tested without a Supabase stack; index.ts wires the real ones.

type RpcResult = { data: unknown; error: unknown };

/** The slice of supabase-js the handler uses. */
export interface DbClient {
  auth: {
    getUser(): PromiseLike<{ data: { user: { id: string } | null }; error: unknown }>;
  };
  from(table: string): {
    select(columns: string): {
      eq(column: string, value: string): { single(): PromiseLike<RpcResult> };
    };
  };
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<RpcResult>;
}

export interface RetrieveMemoryDeps {
  /** Anon-key client carrying the caller's JWT: every read through it is RLS-scoped. */
  userClient(authHeader: string): DbClient;
  /** Service-role client, used only for the embedding match. */
  adminClient(): DbClient;
  /** Throwing here (no Supabase.ai locally) just disables semantic seeds. */
  embedder(): Embedder;
  log(fields: Record<string, unknown>): void;
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const MAX_BODY_BYTES = 1_000_000;
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

async function queryHash(q: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(q));
  return [...new Uint8Array(digest)].slice(0, 4).map((b) => b.toString(16).padStart(2, "0")).join("");
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
    if (!r || typeof r.id !== "string" || typeof r.source !== "string" || typeof r.target !== "string") {
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

// Search indexes survive between requests while the edge isolate stays warm.
// SearchIndex.sync diffs by content hash, so a warm request re-indexes only
// the entities that changed instead of rebuilding all of them. Keys always
// start with the authenticated user's id, so an index never serves another
// user. Requests for the same key run one at a time, because sync and search
// share the index.
const INDEX_CACHE_LIMIT = 32;
const indexCache = new Map<string, { index: SearchIndex; tail: Promise<unknown> }>();

export function indexCacheSize(): number {
  return indexCache.size;
}

function withIndex<T>(key: string, work: (index: SearchIndex) => Promise<T>): Promise<T> {
  let slot = indexCache.get(key);
  if (slot) {
    indexCache.delete(key); // re-insert below: Map order is the LRU order
  } else {
    slot = { index: new SearchIndex(), tail: Promise.resolve() };
    while (indexCache.size >= INDEX_CACHE_LIMIT) {
      indexCache.delete(indexCache.keys().next().value!);
    }
  }
  indexCache.set(key, slot);
  const run = slot.tail.then(() => work(slot!.index));
  slot.tail = run.catch(() => {});
  return run;
}

async function rank(
  cacheKey: string,
  g: GraphState,
  query: string,
  extraSeeds: Map<string, number> | undefined,
) {
  return await withIndex(cacheKey, async (index) => {
    await index.sync(Object.values(g.entities));
    // Communities are only used when nothing matches the query.
    return await retrieve(g, query, { mode: "lexical" }, {
      index,
      communitiesFor: () => buildCommunities(g),
      extraSeeds,
    });
  });
}

export function createHandler(deps: RetrieveMemoryDeps): (req: Request) => Promise<Response> {
  const logTelemetry = deps.log;

  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    const startedAt = Date.now();
    let scope: Scope = "notebook";
    try {
      const raw = await req.text();
      if (raw.length > MAX_BODY_BYTES) return json(413, { error: "body too large" });

      const authHeader = req.headers.get("Authorization");
      if (!authHeader) return json(401, { error: "missing authorization" });
      const supa = deps.userClient(authHeader);
      const { data: { user }, error: userErr } = await supa.auth.getUser();
      if (userErr || !user) return json(401, { error: "invalid session" });

      const body = JSON.parse(raw) as {
        query?: string;
        notebookId?: string;
        scope?: unknown;
        state?: { entities?: Record<string, unknown>; relations?: Record<string, unknown>; entries?: unknown[] };
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
        .from("notebooks").select("id").eq("id", notebookId).single();
      if (nbErr || !nb) return json(404, { error: "notebook not found" });

      // Durable, per-user AND per-notebook rate limit, enforced server-side so a
      // direct JWT caller cannot bypass it the way the Flutter guardrails allow.
      // Window + limits live in the DB function; the client controls nothing, and
      // the function verifies notebook ownership itself.
      const { data: allowed, error: rateErr } = await supa.rpc("bump_retrieve_rate", {
        p_notebook_id: notebookId,
      });
      if (rateErr) {
        logTelemetry({ ok: false, scope, error: "rate_check_failed", latencyMs: Date.now() - startedAt });
        return json(500, { error: "rate check failed" });
      }
      if (allowed === false) {
        logTelemetry({ ok: false, scope, error: "rate_limited", latencyMs: Date.now() - startedAt });
        return json(429, { error: "rate limit exceeded" });
      }

      const query = (body.query ?? "").trim();

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
          logTelemetry({ ok: false, scope, error: "user_graph_failed", latencyMs: Date.now() - startedAt });
          return json(500, { error: "retrieve failed" });
        }
        const g = userGraphToState(graph.data);
        if (Object.keys(g.entities).length === 0) {
          return json(200, retrieveMemoryResponseV2("", [], []));
        }
        const result = await rank(`${user.id}:user`, g, query, extraSeeds);
        const context = buildContext(result);
        const entityIds = result.entities.map((entity) => entity.id);
        const quotes = await loadQuotes(supa, entityIds, notebookId);
        logTelemetry({
          ok: true,
          scope,
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
      const result = await rank(`${user.id}:notebook:${notebookId}`, g, query, extraSeeds);
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
      return json(200, retrieveMemoryResponseV1(
        context,
        result.entities.map((entity) => entity.id),
      ));
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
