import { describe, expect, it } from "vitest";

// The real Lambda handler, with its I/O stubbed. If the web client's request
// drifts from what the runtime validates, this fails instead of every web
// extraction quietly coming back as a 400.
// @ts-expect-error -- untyped .mjs module from the infra package
import { createExtractGraphHandler } from "../../infra/lambda/extract-graph/core.mjs";

import { compileExtractionContext } from "@/lib/extraction-context";
import { createExtractionRuntime } from "@/lib/extraction-runtime-http";
import type { JournalState } from "@/lib/journal-types";

const NOTEBOOK = "8e03b8f4-4f20-4df3-8398-d854adc32b14";
const SUPABASE = "https://supabase.example";
const now = "2026-11-17T00:00:00.000Z";

const state: JournalState = {
  entries: [],
  entities: {
    maya: {
      id: "maya",
      name: "Maya",
      type: "person",
      description: "Friend from university.",
      metadata: {},
      mentions: 3,
      firstSeen: now,
      lastSeen: now,
    },
    "project-atlas": {
      id: "project-atlas",
      name: "Project Atlas",
      type: "project",
      metadata: {},
      mentions: 1,
      firstSeen: now,
      lastSeen: now,
    },
  },
  relations: {
    "maya-works_on-project-atlas": {
      id: "maya-works_on-project-atlas",
      source: "maya",
      target: "project-atlas",
      label: "works_on",
      metadata: {},
      createdAt: now,
    },
  },
  followUps: [],
} as unknown as JournalState;

describe("web extraction against the runtime handler", () => {
  it("is accepted by the runtime and returns the model's patch", async () => {
    const providerCalls: Array<{ headers: Record<string, string>; body: string }> = [];

    const handler = createExtractGraphHandler({
      supabaseUrl: SUPABASE,
      publishableKey: "publishable",
      getPermanentCredential: async () => "server-held-credential",
      acquireExtraction: async () => ({ status: "acquired" }),
      completeExtraction: async ({ patch }: { patch: unknown }) => ({ status: "completed", patch }),
      sleep: async () => {},
      fetchImpl: async (url: string | URL, init: RequestInit = {}) => {
        const href = String(url);
        if (href.includes("/rest/v1/notebooks")) {
          return new Response(JSON.stringify([{ id: NOTEBOOK }]), { status: 200 });
        }
        if (href.includes("/rest/v1/rpc/redact_forgotten_text")) {
          const { p_text } = JSON.parse(String(init.body));
          return new Response(JSON.stringify(p_text), { status: 200 });
        }
        providerCalls.push({
          headers: init.headers as Record<string, string>,
          body: String(init.body),
        });
        return new Response(
          JSON.stringify({
            candidates: [
              {
                content: {
                  parts: [
                    {
                      functionCall: {
                        name: "extract_graph",
                        args: {
                          entities: [{ name: "Maya", type: "person" }],
                          relations: [{ source: "Maya", target: "Project Atlas", label: "leads" }],
                          supersedes: ["maya-works_on-project-atlas"],
                        },
                      },
                    },
                  ],
                },
              },
            ],
          }),
          { status: 200 },
        );
      },
    });

    // API Gateway in front of the handler: the authorizer resolves the user,
    // the path parameter carries the notebook id.
    const gateway = async (url: string | URL, init: RequestInit = {}) => {
      const notebookId = /\/v1\/notebooks\/([^/]+)\/extractions$/.exec(String(url))?.[1];
      const result = await handler({
        headers: init.headers,
        pathParameters: { notebookId: notebookId && decodeURIComponent(notebookId) },
        requestContext: { authorizer: { lambda: { userId: "user-123" } } },
        body: init.body,
      });
      return new Response(result.body, { status: result.statusCode });
    };

    const transcript = "Maya is leading Project Atlas now, not just working on it.";
    const context = compileExtractionContext({
      transcript,
      state,
      retrieval: { entities: [], relations: [] } as never,
      recentTurns: [{ role: "assistant", text: "What's new with Maya?" }],
      answeringFollowUp: undefined,
      budget: 1800,
    });

    const runtime = createExtractionRuntime({
      baseUrl: "https://runtime.example",
      getAccessToken: async () => "user-access-token",
      fetchImpl: gateway as typeof fetch,
      sleep: async () => {},
    });

    const result = await runtime.extract({
      notebookId: NOTEBOOK,
      turnId: "turn-1",
      extractorVersion: "gemini-2.5-flash/extract_graph/v2",
      text: transcript,
      mode: "wiki",
      context: context.clientContext,
    });

    expect(result.entities.map((e) => e.name)).toEqual(["Maya"]);
    expect(result.relations).toEqual([
      expect.objectContaining({ source: "Maya", target: "Project Atlas", label: "leads" }),
    ]);
    expect(result.supersedes).toEqual(["maya-works_on-project-atlas"]);

    // The provider credential is added server-side, and the grounding the web
    // client compiled reached the model.
    expect(providerCalls).toHaveLength(1);
    expect(providerCalls[0].headers["x-goog-api-key"]).toBe("server-held-credential");
    expect(providerCalls[0].body).toContain("Project Atlas");
    expect(providerCalls[0].body).toContain("[maya-works_on-project-atlas]");
  });
});
