import assert from "node:assert/strict";
import test from "node:test";

import { createLiveSessionHandler } from "../lambda/live-session/core.mjs";

test("rejects an unauthenticated invocation before reading the permanent credential", async () => {
  let readCredential = false;
  let madeRequest = false;
  const handle = createLiveSessionHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    getPermanentCredential: async () => {
      readCredential = true;
      return "permanent-test-key";
    },
    fetchImpl: async () => {
      madeRequest = true;
      throw new Error("should not be called");
    },
  });

  const response = await handle({
    headers: { authorization: "Bearer signed-user-token" },
    pathParameters: { notebookId: "8e03b8f4-4f20-4df3-8398-d854adc32b14" },
    requestContext: {},
  });

  assert.equal(response.statusCode, 401);
  assert.deepEqual(JSON.parse(response.body), { error: "unauthorized" });
  assert.equal(readCredential, false);
  assert.equal(madeRequest, false);
});

test("does not mint a credential for a notebook the signed-in user cannot access", async () => {
  let readCredential = false;
  const requests = [];
  const handle = createLiveSessionHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    getPermanentCredential: async () => {
      readCredential = true;
      return "permanent-test-key";
    },
    fetchImpl: async (url, options) => {
      requests.push({ url: String(url), options });
      return { ok: true, json: async () => [] };
    },
  });

  const response = await handle({
    headers: { authorization: "Bearer signed-user-token" },
    pathParameters: { notebookId: "8e03b8f4-4f20-4df3-8398-d854adc32b14" },
    requestContext: {
      authorizer: { lambda: { userId: "user-123" } },
    },
  });

  assert.equal(response.statusCode, 404);
  assert.deepEqual(JSON.parse(response.body), {
    status: "rejected",
    code: "notFound",
  });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].options.headers.authorization, "Bearer signed-user-token");
  assert.equal(readCredential, false);
});

test("returns a constrained one-use live credential for an owned notebook", async () => {
  const requests = [];
  const handle = createLiveSessionHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    model: "gemini-3.1-flash-live-preview",
    now: () => new Date("2026-09-06T16:00:00.000Z"),
    getPermanentCredential: async () => "permanent-test-key",
    fetchImpl: async (url, options) => {
      requests.push({ url: String(url), options });
      if (requests.length === 1) {
        return {
          ok: true,
          json: async () => [{ id: "8e03b8f4-4f20-4df3-8398-d854adc32b14" }],
        };
      }
      return {
        ok: true,
        json: async () => ({ name: "auth_tokens/temporary-token" }),
      };
    },
  });

  const response = await handle({
    headers: { authorization: "Bearer signed-user-token" },
    pathParameters: { notebookId: "8e03b8f4-4f20-4df3-8398-d854adc32b14" },
    requestContext: {
      authorizer: { lambda: { userId: "user-123" } },
    },
  });

  assert.equal(response.statusCode, 200);
  assert.deepEqual(JSON.parse(response.body), {
    status: "ready",
    sessionToken: "auth_tokens/temporary-token",
    expiresAt: "2026-09-06T16:30:00.000Z",
    model: "gemini-3.1-flash-live-preview",
  });
  assert.equal(requests.length, 2);
  assert.equal(requests[1].url, "https://generativelanguage.googleapis.com/v1beta/auth_tokens");
  assert.equal(requests[1].options.headers["x-goog-api-key"], "permanent-test-key");
  assert.deepEqual(JSON.parse(requests[1].options.body), {
    uses: 1,
    expireTime: "2026-09-06T16:30:00.000Z",
    newSessionExpireTime: "2026-09-06T16:01:00.000Z",
    liveConnectConstraints: {
      model: "models/gemini-3.1-flash-live-preview",
      config: { responseModalities: ["AUDIO"] },
    },
  });
  assert.equal(response.body.includes("permanent-test-key"), false);
});
