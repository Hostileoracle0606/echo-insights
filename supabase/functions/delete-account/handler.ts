// Account deletion (App Store Guideline 5.1.1(v)).
//
// The user id comes ONLY from the caller's verified JWT (the `sub` claim, as
// resolved by the auth server) and never from the request body, so a caller
// can delete exactly one account: their own. Every user-data table cascades
// from auth.users, and the on_auth_user_deleted trigger purges the uid-keyed
// rate-limit counters, so one admin delete removes everything
// (supabase/tests/database/account_deletion_test.sql).

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export interface DeleteAccountDeps {
  /** Verifies the bearer token and returns its user id, or null if invalid. */
  verifiedUserId(authorization: string): Promise<string | null>;
  /** Service-role delete of the auth user; cascades to all user data. */
  deleteUser(userId: string): Promise<{ error: unknown | null }>;
  log?(fields: Record<string, unknown>): void;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

export async function handleDeleteAccount(req: Request, deps: DeleteAccountDeps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json(401, { error: "missing authorization" });

  let userId: string | null;
  try {
    userId = await deps.verifiedUserId(authorization);
  } catch {
    userId = null;
  }
  if (!userId) return json(401, { error: "invalid session" });

  const { error } = await deps.deleteUser(userId);
  if (error) {
    // Never log the user id or the provider's error body; just the outcome.
    deps.log?.({ fn: "delete-account", ok: false });
    return json(500, { error: "delete failed" });
  }
  deps.log?.({ fn: "delete-account", ok: true });
  return json(200, { deleted: true });
}
