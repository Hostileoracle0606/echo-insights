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
    acquireExtraction: async () => ({ status: "acquired" }),
    completeExtraction: async ({ patch }) => ({ status: "completed", patch }),
    newOwnerToken: () => "owner-test",
    now: () => 1_800_000_000_000,
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

function inMemoryExtractionStore() {
  let record = null;
  return {
    acquireExtraction: async ({ inputHash, ownerToken, leaseExpiresAt }) => {
      if (!record) {
        record = { status: "pending", inputHash, ownerToken, leaseExpiresAt };
        return { status: "acquired" };
      }
      if (record.inputHash !== inputHash) return { status: "mismatch" };
      if (record.status === "completed") {
        return { status: "completed", patch: record.patch };
      }
      return { status: "pending", retryAfterMs: 250 };
    },
    completeExtraction: async ({ inputHash, ownerToken, patch }) => {
      if (!record || record.inputHash !== inputHash) return { status: "mismatch" };
      if (record.status === "completed") {
        return { status: "completed", patch: record.patch };
      }
      if (record.ownerToken !== ownerToken) {
        return { status: "pending", retryAfterMs: 250 };
      }
      record = { ...record, status: "completed", patch };
      return { status: "completed", patch };
    },
  };
}

test("returns the canonical completed extraction without calling Gemini", async () => {
  const patch = {
    entities: [{ name: "Atlas", type: "project" }],
    relations: [],
    supersedes: [],
  };
  let credentialRead = false;
  let providerCalls = 0;
  const handle = createExtractGraphHandler(
    dependencies({
      acquireExtraction: async () => ({ status: "completed", patch }),
      getPermanentCredential: async () => {
        credentialRead = true;
        return "permanent-test-key";
      },
      fetchImpl: async (url) => {
        if (String(url).includes("/rest/v1/notebooks")) {
          return { ok: true, json: async () => [{ id: notebookId }] };
        }
        providerCalls += 1;
        throw new Error("Gemini must not be called for a completed extraction");
      },
    }),
  );

  const response = await handle(requestEvent());

  assert.equal(response.statusCode, 200);
  assert.deepEqual(JSON.parse(response.body), { patch });
  assert.equal(credentialRead, false);
  assert.equal(providerCalls, 0);
});

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
      completeExtraction: async ({ id, patch }) => {
        cached = { key: id, patch };
        return { status: "completed", patch };
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
      acquireExtraction: async () => ({ status: "completed", patch }),
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

test("does not repeat the Gemini call within one request when completion persistence fails", async () => {
  let requests = 0;
  const handle = createExtractGraphHandler(
    dependencies({
      completeExtraction: async () => {
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

test("retries a transient completion write without calling Gemini again", async () => {
  let providerCalls = 0;
  let completionAttempts = 0;
  const patch = { entities: [], relations: [], supersedes: [] };
  const handle = createExtractGraphHandler(
    dependencies({
      completeExtraction: async () => {
        completionAttempts += 1;
        if (completionAttempts === 1) throw new Error("temporary DynamoDB failure");
        return { status: "completed", patch };
      },
      fetchImpl: async (url) => {
        if (String(url).includes("/rest/v1/notebooks")) {
          return { ok: true, json: async () => [{ id: notebookId }] };
        }
        providerCalls += 1;
        return {
          ok: true,
          status: 200,
          json: async () => ({
            candidates: [{
              content: { parts: [{
                functionCall: { name: "extract_graph", args: patch },
              }] },
            }],
          }),
        };
      },
    }),
  );

  const response = await handle(requestEvent());

  assert.equal(response.statusCode, 200);
  assert.equal(providerCalls, 1);
  assert.equal(completionAttempts, 2);
});

test("overlapping retries share one canonical extraction", async () => {
  const store = inMemoryExtractionStore();
  let releaseProvider;
  const providerBarrier = new Promise((resolve) => {
    releaseProvider = resolve;
  });
  let providerCalls = 0;
  const patch = {
    entities: [{ name: "Maya", type: "person" }],
    relations: [],
    supersedes: [],
  };
  const handle = createExtractGraphHandler(
    dependencies({
      ...store,
      newOwnerToken: (() => {
        let sequence = 0;
        return () => `owner-${++sequence}`;
      })(),
      fetchImpl: async (url) => {
        if (String(url).includes("/rest/v1/notebooks")) {
          return { ok: true, json: async () => [{ id: notebookId }] };
        }
        providerCalls += 1;
        await providerBarrier;
        return {
          ok: true,
          status: 200,
          json: async () => ({
            candidates: [{
              content: { parts: [{
                functionCall: { name: "extract_graph", args: patch },
              }] },
            }],
          }),
        };
      },
    }),
  );

  const first = handle(requestEvent());
  await new Promise((resolve) => setImmediate(resolve));
  const overlapping = await handle(requestEvent());

  assert.equal(overlapping.statusCode, 409);
  assert.deepEqual(JSON.parse(overlapping.body), {
    status: "rejected",
    code: "inProgress",
    retryAfterMs: 250,
  });

  releaseProvider();
  const completed = await first;
  const retried = await handle(requestEvent());

  assert.equal(completed.statusCode, 200);
  assert.deepEqual(JSON.parse(retried.body), { patch });
  assert.equal(providerCalls, 1);
});

test("rejects reuse of a turn identity with different extraction input", async () => {
  const store = inMemoryExtractionStore();
  const patch = { entities: [], relations: [], supersedes: [] };
  const handle = createExtractGraphHandler(
    dependencies({
      ...store,
      fetchImpl: async (url) => {
        if (String(url).includes("/rest/v1/notebooks")) {
          return { ok: true, json: async () => [{ id: notebookId }] };
        }
        return {
          ok: true,
          status: 200,
          json: async () => ({
            candidates: [{
              content: { parts: [{
                functionCall: { name: "extract_graph", args: patch },
              }] },
            }],
          }),
        };
      },
    }),
  );

  assert.equal((await handle(requestEvent())).statusCode, 200);
  const reused = await handle(requestEvent({ text: "Maya moved to Berlin." }));

  assert.equal(reused.statusCode, 409);
  assert.deepEqual(JSON.parse(reused.body), {
    status: "rejected",
    code: "requestIdReused",
  });
});

test("allows rebuilt derived context to recover the same immutable turn", async () => {
  const store = inMemoryExtractionStore();
  const patch = { entities: [], relations: [], supersedes: [] };
  let providerCalls = 0;
  const handle = createExtractGraphHandler(
    dependencies({
      ...store,
      fetchImpl: async (url) => {
        if (String(url).includes("/rest/v1/notebooks")) {
          return { ok: true, json: async () => [{ id: notebookId }] };
        }
        providerCalls += 1;
        return {
          ok: true,
          status: 200,
          json: async () => ({
            candidates: [{
              content: { parts: [{
                functionCall: { name: "extract_graph", args: patch },
              }] },
            }],
          }),
        };
      },
    }),
  );

  assert.equal((await handle(requestEvent())).statusCode, 200);
  const rebuiltContext = requestEvent();
  const body = JSON.parse(rebuiltContext.body);
  body.context.recentConversation = [];
  rebuiltContext.body = JSON.stringify(body);
  const recovered = await handle(rebuiltContext);

  assert.deepEqual(JSON.parse(recovered.body), { patch });
  assert.equal(providerCalls, 1);
});

test("a stale lease owner returns the newer owner's canonical patch", async () => {
  const stalePatch = {
    entities: [{ name: "Maya", type: "person", description: "stale" }],
    relations: [],
    supersedes: [],
  };
  const canonicalPatch = {
    entities: [{ name: "Maya", type: "person", description: "canonical" }],
    relations: [],
    supersedes: [],
  };
  let releaseStaleProvider;
  const staleProviderBarrier = new Promise((resolve) => {
    releaseStaleProvider = resolve;
  });
  let providerCalls = 0;
  let canonical;
  const handle = createExtractGraphHandler(
    dependencies({
      newOwnerToken: (() => {
        let sequence = 0;
        return () => `owner-${++sequence}`;
      })(),
      acquireExtraction: async () => ({ status: "acquired" }),
      completeExtraction: async ({ ownerToken, patch }) => {
        if (ownerToken === "owner-2") canonical = patch;
        return { status: "completed", patch: canonical ?? patch };
      },
      fetchImpl: async (url) => {
        if (String(url).includes("/rest/v1/notebooks")) {
          return { ok: true, json: async () => [{ id: notebookId }] };
        }
        providerCalls += 1;
        const patch = providerCalls === 1 ? stalePatch : canonicalPatch;
        if (providerCalls === 1) await staleProviderBarrier;
        return {
          ok: true,
          status: 200,
          json: async () => ({
            candidates: [{
              content: { parts: [{
                functionCall: { name: "extract_graph", args: patch },
              }] },
            }],
          }),
        };
      },
    }),
  );

  const stale = handle(requestEvent());
  await new Promise((resolve) => setImmediate(resolve));
  const takeover = await handle(requestEvent());
  releaseStaleProvider();
  const staleResult = await stale;

  assert.deepEqual(JSON.parse(takeover.body), { patch: canonicalPatch });
  assert.deepEqual(JSON.parse(staleResult.body), { patch: canonicalPatch });
  assert.equal(providerCalls, 2);
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
