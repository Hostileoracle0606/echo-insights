// Queues deletion of the caller's own account. The user id comes ONLY from the
// verified JWT; the body supplies just `request_id` (idempotency key) and the
// optional Apple code. This function never deletes: a database worker does,
// after a delay (see migration 20261118000200_account_deletion_worker.sql), so
// a lost reply cannot strand the person.

export interface AdminClient {
  auth: {
    /** Server-side token verification (signature + expiry) via the Auth server. */
    getUser(
      jwt: string,
    ): Promise<{
      data: { user: { id: string; identities?: { provider: string }[] } | null };
      error: unknown;
    }>;
  };
}

export interface DeletionQueue {
  find(userId: string, requestId: string): Promise<boolean>;
  /** "exists" when the (user, request) row is already there (unique violation). */
  insert(userId: string, requestId: string): Promise<"inserted" | "exists">;
}

export interface Deps {
  admin: () => AdminClient;
  queue: DeletionQueue;
  now: () => number; // ms
  log: (fields: Record<string, unknown>) => void;
  /** Undefined when Apple secrets are not configured. */
  revokeApple?: (p: { code: string | undefined }) => Promise<boolean>;
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

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The only body fields read. Anything else (including ids) is ignored. */
async function readBody(
  req: Request,
): Promise<{ requestId: string | undefined; code: string | undefined }> {
  try {
    const body = await req.json();
    const r = body?.request_id;
    const c = body?.apple_authorization_code;
    return {
      requestId: typeof r === "string" && UUID.test(r) ? r : undefined,
      code: typeof c === "string" && c ? c : undefined,
    };
  } catch {
    return { requestId: undefined, code: undefined };
  }
}

/** Retries live in apple.ts (the code exchange must not be repeated). Never throws. */
async function tryRevokeApple(
  deps: Deps,
  code: string | undefined,
): Promise<{ revoked: boolean; reason: string }> {
  if (!deps.revokeApple) return { revoked: false, reason: "no_config" };
  if (!code) return { revoked: false, reason: "no_code" };
  try {
    return (await deps.revokeApple({ code }))
      ? { revoked: true, reason: "ok" }
      : { revoked: false, reason: "failed" };
  } catch {
    // swallow: error text could echo the code or Apple's body
    return { revoked: false, reason: "failed" };
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

      const { requestId, code } = await readBody(req);
      if (!requestId) {
        deps.log({ ok: false, error: "bad_request" });
        return json(400, { error: "bad_request" });
      }

      // Already queued (a retry after a lost reply): never revoke Apple twice.
      if (await deps.queue.find(user.id, requestId)) {
        deps.log({ ok: true, event: "delete_account", stage: "already_queued" });
        return json(200, { queued: true, already_queued: true, apple_revoked: null });
      }

      let appleRevoked: boolean | null = null;
      if (user.identities?.some((i) => i.provider === "apple")) {
        const r = await tryRevokeApple(deps, code);
        appleRevoked = r.revoked;
        // `stage` is on safeLog's string allowlist; `reason` would be dropped.
        deps.log({ ok: r.revoked, event: "apple_revoke", stage: r.reason });
      }

      const res = await deps.queue.insert(user.id, requestId);
      if (res === "exists") {
        deps.log({ ok: true, event: "delete_account", stage: "already_queued" });
        return json(200, { queued: true, already_queued: true, apple_revoked: null });
      }
      deps.log({ ok: true, event: "delete_account", stage: "queued" });
      return json(200, { queued: true, already_queued: false, apple_revoked: appleRevoked });
    } catch (e) {
      deps.log({ ok: false, error: e instanceof Error ? e.name : "unknown" });
      return json(500, { queued: false });
    }
  };
}
