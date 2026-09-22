export const NOTEBOOK_RUNTIME_VERSION = "v1" as const;

export type StartLiveSessionOutcome =
  | {
      status: "ready";
      sessionToken: string;
      expiresAt: string;
      model: string;
    }
  | {
      status: "rejected";
      code: "notFound" | "rateLimited" | "providerUnavailable";
    };

/** The production runtime surface implemented by the Segment 1 broker. */
export interface LiveSessionRuntime {
  startLiveSession(request: { notebookId: string }): Promise<StartLiveSessionOutcome>;
}
