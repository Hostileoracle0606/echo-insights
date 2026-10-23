import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { GteSmallEmbedder } from "../_shared/embedder.ts";
import { createHandler, type DbClient } from "./handler.ts";

// Thin entry point: real clients, embedder and log sink. The request logic,
// both scopes and their tests live in handler.ts.

// Non-sensitive SRE telemetry — scope, counts, latency, empty-flag, a short
// query hash. NEVER content (no query, context or quote text). Emitted to the
// function log for ops visibility.
function logTelemetry(fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ fn: "retrieve-memory", ...fields }));
}

serve(createHandler({
  userClient: (authHeader) =>
    createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    ) as unknown as DbClient,
  adminClient: () =>
    createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    ) as unknown as DbClient,
  embedder: () => new GteSmallEmbedder(),
  log: logTelemetry,
}));
