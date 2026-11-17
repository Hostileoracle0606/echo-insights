import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { safeLog } from "../_shared/safe-log.ts";
import { type AdminClient, createHandler } from "./handler.ts";

// Thin entry point: real service-role client, clock and log sink. The request
// logic and its tests live in handler.ts.

serve(
  createHandler({
    admin: () =>
      createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
        { auth: { persistSession: false, autoRefreshToken: false } },
      ) as unknown as AdminClient,
    now: () => Date.now(),
    log: (fields) => safeLog("delete-account", fields),
  }),
);
