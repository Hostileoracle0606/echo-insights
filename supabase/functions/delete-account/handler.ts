// Deletes the caller's own account. The user id comes ONLY from the verified
// JWT; the request body is never read. The auth.users delete cascades to the
// user's data (see migration 20260922000000_account_deletion.sql).

export interface AdminClient {
  auth: {
    /** Server-side token verification (signature + expiry) via the Auth server. */
    getUser(
      jwt: string,
    ): Promise<{
      data: { user: { id: string; identities?: { provider: string }[] } | null };
      error: unknown;
    }>;
    admin: {
      deleteUser(id: string): Promise<{ error: { message: string } | null }>;
    };
  };
}

export interface Deps {
  admin: () => AdminClient;
  now: () => number; // ms
  log: (fields: Record<string, unknown>) => void;
  revokeApple?: (p: { code: string | undefined }) => Promise<boolean>; // added in Task 2
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

/** A stolen older token must not be able to delete the account. */
export const MAX_TOKEN_AGE_SEC = 5 * 60;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const unauthorized = () => json(401, { error: "unauthorized" });

/** `iat` (seconds) from an already-verified JWT, or undefined if unreadable. */
function issuedAt(token: string): number | undefined {
  try {
    const part = token.split(".")[1];
    if (!part) return undefined;
    const b64 = part.replaceAll("-", "+").replaceAll("_", "/");
    const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
    const payload = JSON.parse(atob(padded));
    return typeof payload?.iat === "number" && Number.isFinite(payload.iat)
      ? payload.iat
      : undefined;
  } catch {
    return undefined;
  }
}

export function createHandler(deps: Deps): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (req.method !== "POST") return json(405, { error: "method not allowed" });

    try {
      const header = req.headers.get("Authorization") ?? "";
      const match = /^Bearer\s+(\S+)$/i.exec(header);
      if (!match) {
        deps.log({ ok: false, error: "no_token" });
        return unauthorized();
      }
      const token = match[1];

      const client = deps.admin();
      const { data, error } = await client.auth.getUser(token);
      const user = data?.user;
      if (error || !user) {
        deps.log({ ok: false, error: "invalid_token" });
        return unauthorized();
      }

      const iat = issuedAt(token);
      const ageSec = iat === undefined ? undefined : deps.now() / 1000 - iat;
      if (ageSec === undefined || ageSec > MAX_TOKEN_AGE_SEC) {
        deps.log({ ok: false, error: "stale_token" });
        return unauthorized();
      }

      const { error: delErr } = await client.auth.admin.deleteUser(user.id);
      if (delErr) {
        // Never log the error body: it can echo identifiers.
        deps.log({ ok: false, error: "delete_failed" });
        return json(500, { deleted: false });
      }

      deps.log({ ok: true, event: "deleted" });
      return json(200, { deleted: true, apple_revoked: null });
    } catch (e) {
      deps.log({ ok: false, error: e instanceof Error ? e.name : "unknown" });
      return json(500, { deleted: false });
    }
  };
}
