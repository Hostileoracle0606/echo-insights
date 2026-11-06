import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import type { TableClient } from "../_shared/db-client.ts";
import { GteSmallEmbedder } from "../_shared/embedder.ts";
import { createHandler } from "./handler.ts";

type EdgeGlobal = typeof globalThis & {
  EdgeRuntime?: { waitUntil?(promise: Promise<unknown>): void };
};

serve(
  createHandler({
    adminClient: () =>
      createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      ) as unknown as TableClient,
    embedder: () => new GteSmallEmbedder(),
    env: (name) => Deno.env.get(name),
    fetch,
    // Keeps the runtime from cancelling the in-flight re-enqueue on return.
    waitUntil: (promise) => (globalThis as EdgeGlobal).EdgeRuntime?.waitUntil?.(promise),
  }),
);
