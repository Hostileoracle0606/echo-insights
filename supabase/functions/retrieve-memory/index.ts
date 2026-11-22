import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { GteSmallEmbedder } from "../_shared/embedder.ts";
import { safeLog } from "../_shared/safe-log.ts";
import { createHandler, type DbClient } from "./handler.ts";
import { createDecisionsRouter } from "./decisions.ts";
import { createEvidenceResolver } from "./evidence.ts";

// Thin entry point: real clients, embedder and log sink. The request logic,
// both scopes and their tests live in handler.ts.

// Non-sensitive SRE telemetry — scope, counts, latency, empty-flag, a short
// query hash. NEVER content (no query, context or quote text). Emitted to the
// function log for ops visibility.
function logTelemetry(fields: Record<string, unknown>): void {
  if (fields.version === 3) {
    const { outcome, operation, timeScope, ...metrics } = fields;
    safeLog("retrieve-memory", {
      ...metrics,
      event: outcome,
      stage: operation,
      code: timeScope,
    });
    return;
  }
  safeLog("retrieve-memory", fields);
}

function routeConfiguration() {
  const getApiKey = () => Deno.env.get("MEMORY_QUERY_GEMINI_API_KEY");
  return {
    route: createDecisionsRouter({
      getApiKey,
      observe: ({ elapsedMs, route, confidenceRange, fallbackReason }) =>
        safeLog("memory-decisions", {
          elapsedMs,
          event: route ? "selected" : "fallback",
          stage: route?.operation,
          code: route?.timeScope ?? fallbackReason,
          highConfidence: confidenceRange && confidenceRange === "high",
        }),
    }),
    resolve: createEvidenceResolver({ getApiKey, fetch }),
  };
}

serve(
  createHandler({
    userClient: (authHeader) =>
      createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
        global: { headers: { Authorization: authHeader } },
      }) as unknown as DbClient,
    adminClient: () =>
      createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      ) as unknown as DbClient,
    embedder: () => new GteSmallEmbedder(),
    log: logTelemetry,
    ...(Deno.env.get("MEMORY_QUERY_ROUTING_ENABLED") === "true" && {
      memoryQuery: routeConfiguration(),
    }),
  }),
);
