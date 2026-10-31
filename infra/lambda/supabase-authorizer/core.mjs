function bearerToken(headers = {}) {
  const authorization = headers.authorization ?? headers.Authorization;
  if (typeof authorization !== "string") return null;
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || null;
}

export function createSupabaseAuthorizer({ supabaseUrl, publishableKey, fetchImpl }) {
  return async function authorize(event) {
    const token = bearerToken(event?.headers);
    if (!token) return { isAuthorized: false };

    // API Gateway caches this answer per token, denials included. When
    // Supabase can't answer, throwing fails just this request (a 500 the
    // client retries) instead of locking the token out for the cache's TTL.
    let response;
    try {
      response = await fetchImpl(`${supabaseUrl}/auth/v1/user`, {
        method: "GET",
        headers: {
          apikey: publishableKey,
          authorization: `Bearer ${token}`,
        },
        signal: AbortSignal.timeout(5000),
      });
    } catch (error) {
      throw new Error("Supabase auth is unreachable", { cause: error });
    }
    if (response.status === 429 || response.status >= 500) {
      throw new Error(`Supabase auth answered ${response.status}`);
    }
    if (!response.ok) return { isAuthorized: false };

    try {
      const user = await response.json();
      if (!user || typeof user.id !== "string" || user.id.length === 0) {
        return { isAuthorized: false };
      }

      return {
        isAuthorized: true,
        context: { userId: user.id },
      };
    } catch {
      return { isAuthorized: false };
    }
  };
}
