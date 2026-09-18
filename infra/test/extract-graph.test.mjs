import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { createExtractGraphHandler } from "../lambda/extract-graph/core.mjs";

const notebookId = "8e03b8f4-4f20-4df3-8398-d854adc32b14";
const conversationFixture = JSON.parse(
  await readFile(
    new URL("../../contracts/fixtures/extract-graph-v1.conversation.json", import.meta.url),
    "utf8",
  ),
);

function requestEvent(overrides = {}) {
  return {
    headers: { authorization: "Bearer signed-user-token" },
    pathParameters: { notebookId },
    requestContext: { authorizer: { lambda: { userId: "user-123" } } },
    body: JSON.stringify({
      turnId: "turn-123",
      extractorVersion: "gemini/extract_graph/v2",
      text: "Maya and I discussed Project Atlas.",
      mode: "granular",
      context: {
        entities: [
          { id: "maya", name: "Maya", type: "person" },
          { id: "project-atlas", name: "Project Atlas", type: "project" },
        ],
        relations: [],
        recentConversation: conversationFixture.recentConversation,
        answeringFollowUp: null,
      },
      ...overrides,
    }),
  };
}

function dependencies(overrides = {}) {
  return {
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    getPermanentCredential: async () => "permanent-test-key",
    getCachedPatch: async () => null,
    putCachedPatch: async () => {},
    sleep: async () => {},
    fetchImpl: async (url) => {
      if (String(url).includes("/rest/v1/notebooks")) {
        return { ok: true, json: async () => [{ id: notebookId }] };
      }
      throw new Error("unexpected provider call");
    },
    ...overrides,
  };
}

test("rejects unauthenticated extraction before reading secrets or calling providers", async () => {
  let touchedDependency = false;
  const handle = createExtractGraphHandler(
    dependencies({
      getPermanentCredential: async () => {
        touchedDependency = true;
        return "permanent-test-key";
      },
      fetchImpl: async () => {
        touchedDependency = true;
        throw new Error("should not be called");
      },
    }),
  );

  const event = requestEvent();
  event.requestContext = {};
  const response = await handle(event);

  assert.equal(response.statusCode, 401);
  assert.equal(touchedDependency, false);
});

test("returns a validated patch without returning the permanent credential", async () => {
  const requests = [];
  let cached;
  const handle = createExtractGraphHandler(
    dependencies({
      putCachedPatch: async (key, patch) => {
        cached = { key, patch };
      },
      fetchImpl: async (url, options) => {
        requests.push({ url: String(url), options });
        if (requests.length === 1) {
          return { ok: true, json: async () => [{ id: notebookId }] };
        }
        return {
          ok: true,
          status: 200,
          json: async () => ({
            candidates: [
              {
                content: {
                  parts: [
                    {
                      functionCall: {
                        name: "extract_graph",
                        args: {
                          entities: [{ name: "Maya", type: "person" }],
                          relations: [],
                          supersedes: [],
                        },
                      },
                    },
                  ],
                },
              },
            ],
          }),
        };
      },
    }),
  );

  const response = await handle(requestEvent());
  const body = JSON.parse(response.body);

  assert.equal(response.statusCode, 200);
  assert.deepEqual(body.patch, {
    entities: [{ name: "Maya", type: "person" }],
    relations: [],
    supersedes: [],
  });
  assert.equal(response.body.includes("permanent-test-key"), false);
  assert.equal(requests.length, 2);
  assert.equal(
    requests[1].url,
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
  );
  assert.equal(requests[1].options.headers["x-goog-api-key"], "permanent-test-key");
  const providerBody = JSON.parse(requests[1].options.body);
  assert.match(providerBody.contents[0].parts[0].text, /Maya and I discussed Project Atlas/);
  assert.equal(cached.key, `user-123:${notebookId}:turn-123:gemini/extract_graph/v2`);
  assert.deepEqual(cached.patch, body.patch);
});

test("returns a cached patch without reading the credential or calling Gemini", async () => {
  const patch = {
    entities: [{ name: "Atlas", type: "project" }],
    relations: [],
    supersedes: [],
  };
  let credentialRead = false;
  let requests = 0;
  const handle = createExtractGraphHandler(
    dependencies({
      getCachedPatch: async () => patch,
      getPermanentCredential: async () => {
        credentialRead = true;
        return "permanent-test-key";
      },
      fetchImpl: async (url) => {
        requests += 1;
        assert.match(String(url), /rest\/v1\/notebooks/);
        return { ok: true, json: async () => [{ id: notebookId }] };
      },
    }),
  );

  const response = await handle(requestEvent());

  assert.equal(response.statusCode, 200);
  assert.deepEqual(JSON.parse(response.body), { patch });
  assert.equal(requests, 1);
  assert.equal(credentialRead, false);
});

test("does not repeat the Gemini call when writing the retry cache fails", async () => {
  let requests = 0;
  const handle = createExtractGraphHandler(
    dependencies({
      putCachedPatch: async () => {
        throw new Error("cache unavailable");
      },
      fetchImpl: async () => {
        requests += 1;
        if (requests === 1) {
          return { ok: true, json: async () => [{ id: notebookId }] };
        }
        return {
          ok: true,
          status: 200,
          json: async () => ({
            candidates: [
              {
                content: {
                  parts: [
                    {
                      functionCall: {
                        name: "extract_graph",
                        args: { entities: [], relations: [], supersedes: [] },
                      },
                    },
                  ],
                },
              },
            ],
          }),
        };
      },
    }),
  );

  const response = await handle(requestEvent());

  assert.equal(response.statusCode, 503);
  assert.equal(requests, 2);
});

test("rejects malformed extraction requests before checking notebook ownership", async () => {
  let requested = false;
  const handle = createExtractGraphHandler(
    dependencies({
      fetchImpl: async () => {
        requested = true;
        throw new Error("should not be called");
      },
    }),
  );

  const response = await handle(requestEvent({ text: " " }));

  assert.equal(response.statusCode, 400);
  assert.deepEqual(JSON.parse(response.body), { error: "invalidRequest" });
  assert.equal(requested, false);
});

test("rejects the legacy agent role at the canonical extraction seam", async () => {
  let requested = false;
  const handle = createExtractGraphHandler(
    dependencies({
      fetchImpl: async () => {
        requested = true;
        throw new Error("should not be called");
      },
    }),
  );

  const event = requestEvent();
  const body = JSON.parse(event.body);
  body.context.recentConversation = [{ role: "agent", text: "Legacy label" }];
  event.body = JSON.stringify(body);

  const response = await handle(event);

  assert.equal(response.statusCode, 400);
  assert.deepEqual(JSON.parse(response.body), { error: "invalidRequest" });
  assert.equal(requested, false);
});
