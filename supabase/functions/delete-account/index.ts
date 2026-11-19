import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { safeLog } from "../_shared/safe-log.ts";
import { appleConfigFromEnv, revokeAppleAccess } from "./apple.ts";
import { type AdminClient, createHandler, type DeletionQueue } from "./handler.ts";

// Thin entry point: real service-role client, clock and log sink. The request
// logic and its tests live in handler.ts.

const appleCfg = appleConfigFromEnv(Deno.env);

// Service role may only SELECT and INSERT on account_deletion_requests.
const db = () =>
  createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

const queue: DeletionQueue = {
  async find(userId, requestId) {
    const { data, error } = await db().from("account_deletion_requests").select("request_id")
      .eq("user_id", userId).eq("request_id", requestId).limit(1);
    if (error) throw new Error("queue_find_failed"); // never carry the server body
    return (data?.length ?? 0) > 0;
  },
  async insert(userId, requestId) {
    const { error } = await db().from("account_deletion_requests")
      .insert({ user_id: userId, request_id: requestId });
    if (!error) return "inserted";
    if (error.code === "23505") return "exists";
    throw new Error("queue_insert_failed");
  },
};

serve(
  createHandler({
    admin: () => db() as unknown as AdminClient,
    queue,
    now: () => Date.now(),
    revokeApple: appleCfg
      ? ({ code }) =>
        code
          ? revokeAppleAccess({ cfg: appleCfg, code, fetch, now: () => Date.now() })
          : Promise.resolve(false)
      : undefined,
    log: (fields) => safeLog("delete-account", fields),
  }),
);
