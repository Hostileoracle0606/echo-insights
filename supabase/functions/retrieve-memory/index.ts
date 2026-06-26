import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { retrieve } from "../_shared/graphloop/retrieve.ts";
import { SearchIndex } from "../_shared/graphloop/search-index.ts";
import { buildCommunities } from "../_shared/graphloop/communities.ts";
import type { GraphState } from "../_shared/graphloop/types.ts";
import { buildContext } from "./context.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const MAX_BODY_BYTES = 1_000_000;
const MAX_ENTITIES = 2000;
const MAX_RELATIONS = 4000;
const MAX_ENTRIES = 2000;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

// Non-sensitive SRE telemetry — counts, latency, empty-flag, a short query hash.
// NEVER content. Emitted to the function log for ops visibility.
function logTelemetry(fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ fn: "retrieve-memory", ...fields }));
}

async function queryHash(q: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(q));
  return [...new Uint8Array(digest)].slice(0, 4).map((b) => b.toString(16).padStart(2, "0")).join("");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  const startedAt = Date.now();
  try {
    const raw = await req.text();
    if (raw.length > MAX_BODY_BYTES) return json(413, { error: "body too large" });

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json(401, { error: "missing authorization" });
    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: userErr } = await supa.auth.getUser();
    if (userErr || !user) return json(401, { error: "invalid session" });

    const body = JSON.parse(raw) as {
      query?: string;
      notebookId?: string;
      state?: { entities?: Record<string, unknown>; relations?: Record<string, unknown>; entries?: unknown[] };
    };

    const notebookId = body.notebookId;
    if (!notebookId) return json(400, { error: "notebookId required" });
    const { data: nb, error: nbErr } = await supa
      .from("notebooks").select("id").eq("id", notebookId).single();
    if (nbErr || !nb) return json(404, { error: "notebook not found" });

    const query = (body.query ?? "").trim();
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
    if (!query || Object.keys(entities).length === 0) return json(200, { context: "" });

    const g = { entities, relations, entries } as unknown as GraphState;
    const index = new SearchIndex();
    await index.sync(Object.values(g.entities));
    const communities = buildCommunities(g);
    const result = await retrieve(g, query, { mode: "lexical" }, { index, communities });
    const context = buildContext(result);
    logTelemetry({
      ok: true,
      entityCount: result.entities.length,
      relationCount: result.relations.length,
      seedCount: result.seeds.length,
      emptyContext: context.length === 0,
      latencyMs: Date.now() - startedAt,
      qHash: await queryHash(query),
    });
    return json(200, { context });
  } catch (e) {
    // Never log the request body or context. Counts / error name only.
    logTelemetry({
      ok: false,
      error: e instanceof Error ? e.name : "unknown",
      latencyMs: Date.now() - startedAt,
    });
    return json(500, { error: "retrieve failed" });
  }
});
