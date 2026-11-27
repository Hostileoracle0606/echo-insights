import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { GteSmallEmbedder } from "../_shared/embedder.ts";
import { errorClass, safeLog } from "../_shared/safe-log.ts";
import { createHandler, type DbClient } from "./handler.ts";
import { createDecisionsRouter } from "./decisions.ts";
import { createHttpMemoryReranker, DEFAULT_RERANK_BUDGET_MS } from "./memory-reranker.ts";
import { createEdgeMemoryReranker } from "./memory-reranker-edge.ts";
import { loadVerifiedModel } from "./model-artifact.ts";
import rerankManifest from "../_shared/reranker/manifest.json" with { type: "json" };

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
  };
}

function rerankerConfiguration() {
  const endpoint = Deno.env.get("MEMORY_RERANKER_URL")?.trim();
  if (!endpoint) return {};
  const rawTimeout = Deno.env.get("MEMORY_RERANKER_TIMEOUT_MS");
  const timeoutMs = rawTimeout ? Number(rawTimeout) : DEFAULT_RERANK_BUDGET_MS;
  const rawCandidateCount = Deno.env.get("MEMORY_RERANKER_CANDIDATE_COUNT");
  const candidateCount = rawCandidateCount ? Number(rawCandidateCount) : 12;
  try {
    if (!Number.isInteger(candidateCount) || candidateCount < 1 || candidateCount > 32) {
      throw new RangeError("Invalid candidate count");
    }
    return {
      rerankerCandidateCount: candidateCount,
      rerankerBudgetMs: timeoutMs,
      reranker: createHttpMemoryReranker({
        endpoint,
        timeoutMs,
        bearerToken: Deno.env.get("MEMORY_RERANKER_BEARER_TOKEN") ?? undefined,
      }),
    };
  } catch (error) {
    safeLog("retrieve-memory", {
      event: "reranker_configuration_invalid",
      error: error instanceof Error ? error.name : "unknown",
    });
    return {};
  }
}

// The paired live reranker experiment is available only in a local Supabase
// Edge runtime with an explicit opt-in. The endpoint accepted here remains
// loopback; only the injected fetch transport bridges the Edge container to
// the host process. Production adapter validation and transport are unchanged.
function localEvalConfiguration() {
  if (Deno.env.get("LUMEN_ENABLE_LOCAL_EVAL_ARMS") !== "true" || Deno.env.get("DENO_DEPLOYMENT_ID")) return {};
  const endpoint = Deno.env.get("LUMEN_EVAL_RERANKER_LOOPBACK_URL")?.trim();
  if (!endpoint) return { evalSelectionArms: true, reranker: undefined };
  try {
    const localUrl = new URL(endpoint);
    if (localUrl.protocol !== "http:" || !["127.0.0.1", "localhost", "[::1]"].includes(localUrl.hostname)) {
      throw new TypeError("Eval reranker URL must be loopback HTTP");
    }
    const rawTimeout = Deno.env.get("MEMORY_RERANKER_TIMEOUT_MS");
    const timeoutMs = rawTimeout ? Number(rawTimeout) : DEFAULT_RERANK_BUDGET_MS;
    const fetchBridge: typeof fetch = (input, init) => {
      const target = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
      target.hostname = "host.docker.internal";
      return fetch(target, init);
    };
    return {
      evalSelectionArms: true,
      rerankerBudgetMs: timeoutMs,
      reranker: createHttpMemoryReranker({
        endpoint: localUrl.href, timeoutMs, fetchImpl: fetchBridge,
        bearerToken: Deno.env.get("MEMORY_RERANKER_BEARER_TOKEN") ?? undefined,
      }),
    };
  } catch (error) {
    safeLog("retrieve-memory", {
      event: "local_eval_reranker_configuration_invalid",
      error: error instanceof Error ? error.name : "unknown",
    });
    return { evalSelectionArms: true, reranker: undefined };
  }
}

// RERANKER_MODE=shadow|on turns the reranker on for the default live path (v2).
// It is MEMORY_RERANKER_URL's HTTP service when that is set, otherwise the
// pool-trained 2-layer model served in this function (_shared/reranker). Its
// weights live in the project's private `ml-models` bucket under their hash
// (ml/reranker/deploy/upload_model.sh); only the vocabulary ships as a static file.
// Scoring code loads on the first scored call, so cold starts with it off are unchanged.
function defaultPathReranker() {
  const mode = Deno.env.get("RERANKER_MODE");
  if (mode !== "shadow" && mode !== "on") return {};
  const timeoutMs = Number(Deno.env.get("RERANKER_TIMEOUT_MS") ?? 1200);
  const dir = new URL("../_shared/reranker/", import.meta.url);
  // The model is a stored artifact (bucket ml-models), refused unless it matches the pin.
  let modelBytes: Promise<Uint8Array> | null = null;
  const model = () => (modelBytes ??= loadVerifiedModel({
    sha256: rerankManifest.sha256,
    download: async (path) => {
      const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      const { data, error } = await admin.storage.from("ml-models").download(path);
      if (error || !data) throw new Error("Reranker model unavailable");
      return new Uint8Array(await data.arrayBuffer());
    },
  }).catch((error) => {
    modelBytes = null;
    throw error;
  }));
  let scorer: Promise<(query: string, cards: string[]) => Promise<number[]>> | null = null;
  const getScorer = () => (scorer ??= import("../_shared/reranker/scorer.ts").then(({ createReranker }) => createReranker({
    model,
    vocab: () => Deno.readTextFile(new URL("vocab.txt", dir)),
    maxLength: rerankManifest.max_length,
    timeoutMs,
  })).catch((error) => {
    scorer = null;
    throw error;
  }));
  // No warm-up at boot: an edge worker is retired after about a second of CPU, and
  // loading the session costs about half of that, so a worker pays for the model only
  // when it first scores. That first load is logged by stage (content-free).
  let loaded: Promise<void> | null = null;
  const ensureLoaded = () => (loaded ??= (async () => {
    const started = Date.now();
    let stage = "download";
    try {
      await model();
      stage = "session";
      await (await getScorer())("load", ["load"]); // creates the session (it is lazy)
      safeLog("retrieve-memory", { event: "reranker_load", stage: "ready", ms: Date.now() - started });
    } catch (error) {
      safeLog("retrieve-memory", { event: "reranker_load", stage, error: errorClass(error), ms: Date.now() - started });
      loaded = null;
      throw error;
    }
  })());
  const edge = createEdgeMemoryReranker({
    timeoutMs,
    score: async (query, cards) => {
      await ensureLoaded();
      return (await getScorer())(query, cards);
    },
  });
  // deno-lint-ignore no-explicit-any
  const edgeRuntime = (globalThis as any).EdgeRuntime as { waitUntil?: (p: Promise<unknown>) => void } | undefined;
  return {
    rerankMode: mode as "shadow" | "on",
    ...(Deno.env.get("MEMORY_RERANKER_URL")?.trim() ? {} : { reranker: edge }),
    ...(edgeRuntime?.waitUntil && { waitUntil: (work: Promise<unknown>) => edgeRuntime.waitUntil!(work) }),
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
    ...rerankerConfiguration(),
    ...defaultPathReranker(),
    ...localEvalConfiguration(),
  }),
);
