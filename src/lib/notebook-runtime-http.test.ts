import { describe, expect, it, vi } from "vitest";

import { createLiveSessionRuntime } from "./notebook-runtime-http";

describe("live-session runtime adapter", () => {
  it("uses the current Supabase access token to request a temporary live credential", async () => {
    const fetchImpl = vi.fn(async () =>
      Response.json({
        status: "ready",
        sessionToken: "auth_tokens/temporary-token",
        expiresAt: "2026-09-07T12:30:00.000Z",
        model: "gemini-3.1-flash-live-preview",
      }),
    );
    const runtime = createLiveSessionRuntime({
      baseUrl: "https://runtime.example.com/",
      getAccessToken: async () => "signed-user-token",
      fetchImpl,
    });

    const outcome = await runtime.startLiveSession({
      notebookId: "8e03b8f4-4f20-4df3-8398-d854adc32b14",
    });

    expect(outcome).toEqual({
      status: "ready",
      sessionToken: "auth_tokens/temporary-token",
      expiresAt: "2026-09-07T12:30:00.000Z",
      model: "gemini-3.1-flash-live-preview",
    });
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://runtime.example.com/v1/notebooks/8e03b8f4-4f20-4df3-8398-d854adc32b14/live-sessions",
      {
        method: "POST",
        headers: {
          accept: "application/json",
          authorization: "Bearer signed-user-token",
        },
      },
    );
  });

  it("does not call the runtime when there is no signed-in session", async () => {
    const fetchImpl = vi.fn();
    const runtime = createLiveSessionRuntime({
      baseUrl: "https://runtime.example.com",
      getAccessToken: async () => null,
      fetchImpl,
    });

    await expect(
      runtime.startLiveSession({
        notebookId: "8e03b8f4-4f20-4df3-8398-d854adc32b14",
      }),
    ).rejects.toThrow("A signed-in session is required");
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("returns an expected broker rejection as a domain outcome", async () => {
    const runtime = createLiveSessionRuntime({
      baseUrl: "https://runtime.example.com",
      getAccessToken: async () => "signed-user-token",
      fetchImpl: vi.fn(async () =>
        Response.json({ status: "rejected", code: "rateLimited" }, { status: 429 }),
      ),
    });

    await expect(
      runtime.startLiveSession({
        notebookId: "8e03b8f4-4f20-4df3-8398-d854adc32b14",
      }),
    ).resolves.toEqual({ status: "rejected", code: "rateLimited" });
  });

  it("rejects expired authentication and malformed broker responses", async () => {
    const expired = createLiveSessionRuntime({
      baseUrl: "https://runtime.example.com",
      getAccessToken: async () => "expired-token",
      fetchImpl: vi.fn(async () => new Response(null, { status: 401 })),
    });
    await expect(
      expired.startLiveSession({
        notebookId: "8e03b8f4-4f20-4df3-8398-d854adc32b14",
      }),
    ).rejects.toThrow("The signed-in session is no longer valid");

    const malformed = createLiveSessionRuntime({
      baseUrl: "https://runtime.example.com",
      getAccessToken: async () => "signed-user-token",
      fetchImpl: vi.fn(async () => Response.json({ status: "ready" })),
    });
    await expect(
      malformed.startLiveSession({
        notebookId: "8e03b8f4-4f20-4df3-8398-d854adc32b14",
      }),
    ).rejects.toThrow("The Notebook Runtime returned an invalid live-session response");
  });
});
