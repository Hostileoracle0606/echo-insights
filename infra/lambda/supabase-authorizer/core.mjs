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

    try {
      const response = await fetchImpl(`${supabaseUrl}/auth/v1/user`, {
        method: "GET",
        headers: {
          apikey: publishableKey,
          authorization: `Bearer ${token}`,
        },
        signal: AbortSignal.timeout(5000),
      });
      if (!response.ok) return { isAuthorized: false };

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
