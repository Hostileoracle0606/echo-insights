import { describe, expect, it, vi } from "vitest";

import { createExtractionRuntime, toRuntimeContext } from "@/lib/extraction-runtime-http";

const NOTEBOOK = "0b6b5b0e-6c38-4d0f-9d3a-0e2a4c1b7f10";

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

const request = {
  notebookId: NOTEBOOK,
  turnId: "turn-1",
  extractorVersion: "v2",
  text: "I had coffee with Maya today.",
  mode: "wiki" as const,
  context: {
    existingEntities: [{ id: "maya", name: "Maya", type: "person" }],
    existingRelations: [{ id: "r1", source: "Maya", target: "Maya", label: "knows" }],
    recentConversation: [{ role: "assistant" as const, text: "How was your day?" }],
  },
};

function runtime(fetchImpl: typeof fetch, token: string | null = "access-token") {
  return createExtractionRuntime({
    baseUrl: "https://runtime.example/",
    getAccessToken: async () => token,
    fetchImpl,
    sleep: async () => {},
  });
}

describe("createExtractionRuntime", () => {
  it("posts the turn to the notebook's extraction route with the user's token only", async () => {
    const fetchImpl = vi.fn(async () =>
      json(200, {
        patch: {
          entities: [{ name: "Maya", type: "person" }],
          relations: [],
          supersedes: [],
        },
      }),
    );

    const result = await runtime(fetchImpl as unknown as typeof fetch).extract(request);

    expect(result.entities.map((e) => e.name)).toEqual(["Maya"]);
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe(`https://runtime.example/v1/notebooks/${NOTEBOOK}/extractions`);
    expect(init.method).toBe("POST");
    const headers = init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer access-token");
    expect(Object.keys(headers).some((h) => /goog|api-key/i.test(h))).toBe(false);
    const body = JSON.parse(String(init.body));
    expect(body).toMatchObject({
      turnId: "turn-1",
      extractorVersion: "v2#wiki",
      text: request.text,
      mode: "wiki",
    });
    // Relation endpoints are sent as entity ids.
    expect(body.context.relations[0]).toMatchObject({ source: "maya", target: "maya" });
  });

  it("does not call the runtime without a signed-in session", async () => {
    const fetchImpl = vi.fn();
    await expect(
      runtime(fetchImpl as unknown as typeof fetch, null).extract(request),
    ).rejects.toThrow("signed-in");
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("skips turns too short for the runtime to accept", async () => {
    const fetchImpl = vi.fn();
    const result = await runtime(fetchImpl as unknown as typeof fetch).extract({
      ...request,
      text: " ok ",
    });
    expect(result.entities).toEqual([]);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("waits on an in-progress extraction without spending retries", async () => {
    const responses = [
      json(409, { status: "rejected", code: "inProgress", retryAfterMs: 10 }),
      json(409, { status: "rejected", code: "inProgress", retryAfterMs: 10 }),
      json(409, { status: "rejected", code: "inProgress", retryAfterMs: 10 }),
      json(200, { patch: { entities: [], relations: [] } }),
    ];
    const fetchImpl = vi.fn(async () => responses.shift()!);
    await runtime(fetchImpl as unknown as typeof fetch).extract(request);
    expect(fetchImpl).toHaveBeenCalledTimes(4);
  });

  it("retries rate limits, then reports them", async () => {
    const fetchImpl = vi.fn(async () => json(429, { status: "rejected", code: "rateLimited" }));
    await expect(runtime(fetchImpl as unknown as typeof fetch).extract(request)).rejects.toThrow(
      "Rate limit",
    );
    expect(fetchImpl).toHaveBeenCalledTimes(3);
  });

  it("treats an expired session as fatal", async () => {
    const fetchImpl = vi.fn(async () => json(401, { error: "unauthorized" }));
    await expect(runtime(fetchImpl as unknown as typeof fetch).extract(request)).rejects.toThrow(
      "no longer valid",
    );
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("skips a turn the runtime rejects as invalid", async () => {
    const fetchImpl = vi.fn(async () => json(400, { error: "invalidRequest" }));
    const result = await runtime(fetchImpl as unknown as typeof fetch).extract(request);
    expect(result.entities).toEqual([]);
  });
});

describe("toRuntimeContext", () => {
  it("trims the context to the runtime's request limits", () => {
    const context = toRuntimeContext({
      existingEntities: Array.from({ length: 30 }, (_, i) => ({
        id: `e${i}`,
        name: `Entity ${i}`,
        type: i === 0 ? "made-up" : "person",
        description: "x".repeat(2000),
      })),
      existingRelations: [],
      recentConversation: Array.from({ length: 8 }, (_, i) => ({
        role: "user" as const,
        text: `turn ${i}`,
      })),
      answeringFollowUp: { question: "How did you meet?" },
    });

    expect(context.entities).toHaveLength(20);
    expect(context.entities[0].type).toBe("other");
    expect(context.entities[0].description!.length).toBeLessThanOrEqual(1000);
    expect(context.recentConversation.map((t) => t.text)).toEqual([
      "turn 4",
      "turn 5",
      "turn 6",
      "turn 7",
    ]);
    expect(context.answeringFollowUp).toEqual({ question: "How did you meet?", reason: "" });
  });
});
