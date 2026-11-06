import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { GteSmallEmbedder } from "../_shared/embedder.ts";
import { createHandler } from "./handler.ts";

serve(
  createHandler({
    adminClient: () =>
      createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!),
    embedder: () => new GteSmallEmbedder(),
    env: (name) => Deno.env.get(name),
    fetch,
    // Keeps the runtime from cancelling the in-flight re-enqueue on return.
    // deno-lint-ignore no-explicit-any
    waitUntil: (promise) => (globalThis as any).EdgeRuntime?.waitUntil?.(promise),
  }),
);
