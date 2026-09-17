import type { LiveSessionRuntime, StartLiveSessionOutcome } from "./notebook-runtime-contract";

export type { LiveSessionRuntime } from "./notebook-runtime-contract";

type LiveSessionRuntimeOptions = {
  baseUrl: string;
  getAccessToken: () => Promise<string | null>;
  fetchImpl?: typeof fetch;
};

function isStartLiveSessionOutcome(value: unknown): value is StartLiveSessionOutcome {
  if (!value || typeof value !== "object") return false;
  const outcome = value as Record<string, unknown>;
  if (outcome.status === "ready") {
    return (
      typeof outcome.sessionToken === "string" &&
      typeof outcome.expiresAt === "string" &&
      typeof outcome.model === "string"
    );
  }
  return (
    outcome.status === "rejected" &&
    (outcome.code === "notFound" ||
      outcome.code === "rateLimited" ||
      outcome.code === "providerUnavailable")
  );
}

export function createLiveSessionRuntime({
  baseUrl,
  getAccessToken,
  fetchImpl = fetch,
}: LiveSessionRuntimeOptions): LiveSessionRuntime {
  const normalizedBaseUrl = baseUrl.replace(/\/$/, "");

  return {
    async startLiveSession({ notebookId }) {
      const accessToken = await getAccessToken();
      if (!accessToken) throw new Error("A signed-in session is required");

      const response = await fetchImpl(
        `${normalizedBaseUrl}/v1/notebooks/${encodeURIComponent(notebookId)}/live-sessions`,
        {
          method: "POST",
          headers: {
            accept: "application/json",
            authorization: `Bearer ${accessToken}`,
          },
        },
      );

      if (response.status === 401 || response.status === 403) {
        throw new Error("The signed-in session is no longer valid");
      }

      const outcome: unknown = await response.json();
      if (!isStartLiveSessionOutcome(outcome)) {
        throw new Error("The Notebook Runtime returned an invalid live-session response");
      }
      return outcome;
    },
  };
}
