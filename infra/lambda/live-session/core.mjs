function jsonResponse(statusCode, body) {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

function authorizedUserId(event) {
  const value = event?.requestContext?.authorizer?.lambda?.userId;
  return typeof value === "string" && value.length > 0 ? value : null;
}

function bearerAuthorization(headers = {}) {
  const value = headers.authorization ?? headers.Authorization;
  return typeof value === "string" && /^Bearer\s+\S+/i.test(value) ? value : null;
}

function notebookIdFrom(event) {
  const value = event?.pathParameters?.notebookId;
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

export function createLiveSessionHandler({
  supabaseUrl,
  publishableKey,
  getPermanentCredential,
  fetchImpl,
  model = "gemini-3.1-flash-live-preview",
  now = () => new Date(),
}) {
  return async function handle(event) {
    if (!authorizedUserId(event)) {
      return jsonResponse(401, { error: "unauthorized" });
    }

    const authorization = bearerAuthorization(event?.headers);
    if (!authorization) {
      return jsonResponse(401, { error: "unauthorized" });
    }

    const notebookId = notebookIdFrom(event);
    if (!notebookId) {
      return jsonResponse(400, { error: "invalidRequest" });
    }

    const notebookUrl = new URL("/rest/v1/notebooks", supabaseUrl);
    notebookUrl.searchParams.set("select", "id");
    notebookUrl.searchParams.set("id", `eq.${notebookId}`);
    notebookUrl.searchParams.set("limit", "1");

    try {
      const response = await fetchImpl(notebookUrl, {
        method: "GET",
        headers: {
          accept: "application/json",
          apikey: publishableKey,
          authorization,
        },
        signal: AbortSignal.timeout(5000),
      });
      if (!response.ok) {
        return jsonResponse(503, {
          status: "rejected",
          code: "providerUnavailable",
        });
      }

      const notebooks = await response.json();
      if (!Array.isArray(notebooks) || notebooks.length === 0) {
        return jsonResponse(404, {
          status: "rejected",
          code: "notFound",
        });
      }
    } catch {
      return jsonResponse(503, {
        status: "rejected",
        code: "providerUnavailable",
      });
    }

    const issuedAt = now();
    const expireTime = new Date(issuedAt.getTime() + 30 * 60 * 1000).toISOString();
    const newSessionExpireTime = new Date(issuedAt.getTime() + 60 * 1000).toISOString();

    try {
      const permanentCredential = (await getPermanentCredential()).trim();
      if (!permanentCredential) throw new Error("Gemini credential is empty");

      const response = await fetchImpl(
        "https://generativelanguage.googleapis.com/v1beta/auth_tokens",
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-goog-api-key": permanentCredential,
          },
          body: JSON.stringify({
            uses: 1,
            expireTime,
            newSessionExpireTime,
            liveConnectConstraints: {
              model: `models/${model}`,
              config: { responseModalities: ["AUDIO"] },
            },
          }),
          signal: AbortSignal.timeout(5000),
        },
      );
      if (!response.ok) throw new Error("Gemini rejected the token request");

      const token = await response.json();
      if (!token || typeof token.name !== "string" || token.name.length === 0) {
        throw new Error("Gemini returned no token");
      }

      return jsonResponse(200, {
        status: "ready",
        sessionToken: token.name,
        expiresAt: expireTime,
        model,
      });
    } catch {
      return jsonResponse(503, {
        status: "rejected",
        code: "providerUnavailable",
      });
    }
  };
}
