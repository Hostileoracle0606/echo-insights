import assert from "node:assert/strict";
import test from "node:test";

import {
  createLiveSessionHandler,
  resolveUserStartWindowSeconds,
} from "../lambda/live-session/core.mjs";

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
    newSessionExpiresAt: "2026-09-06T16:01:00.000Z",
    model: "gemini-3.1-flash-live-preview",
  });
  assert.equal(requests.length, 2);
  assert.equal(requests[1].url, "https://generativelanguage.googleapis.com/v1beta/auth_tokens");
  assert.equal(requests[1].options.headers["x-goog-api-key"], "permanent-test-key");
  assert.deepEqual(JSON.parse(requests[1].options.body), {
    uses: 1,
    expireTime: "2026-09-06T16:30:00.000Z",
    newSessionExpireTime: "2026-09-06T16:01:00.000Z",
    fieldMask: "model,generationConfig.responseModalities",
    bidiGenerateContentSetup: {
      model: "models/gemini-3.1-flash-live-preview",
      generationConfig: { responseModalities: ["AUDIO"] },
    },
  });
  assert.equal(response.body.includes("permanent-test-key"), false);
});

const signedInUserEvent = {
  headers: { authorization: "Bearer signed-user-token" },
  requestContext: {
    authorizer: { lambda: { userId: "user-123" } },
  },
};

function userRouteHandler(options = {}) {
  const requests = [];
  const handle = createLiveSessionHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    model: "gemini-3.1-flash-live-preview",
    now: () => new Date("2026-09-06T16:00:00.000Z"),
    getPermanentCredential: async () => "permanent-test-key",
    fetchImpl: async (url, init) => {
      requests.push({ url: String(url), options: init });
      return {
        ok: true,
        json: async () => ({ name: "auth_tokens/temporary-token" }),
      };
    },
    ...options,
  });
  return { handle, requests };
}

test("user route rejects an unauthenticated invocation before any request", async () => {
  let readCredential = false;
  const { handle, requests } = userRouteHandler({
    getPermanentCredential: async () => {
      readCredential = true;
      return "permanent-test-key";
    },
  });

  const unauthorized = await handle({
    headers: { authorization: "Bearer signed-user-token" },
    requestContext: {},
  });
  const missingBearer = await handle({
    headers: {},
    requestContext: signedInUserEvent.requestContext,
  });

  assert.equal(unauthorized.statusCode, 401);
  assert.deepEqual(JSON.parse(unauthorized.body), { error: "unauthorized" });
  assert.equal(missingBearer.statusCode, 401);
  assert.equal(requests.length, 0);
  assert.equal(readCredential, false);
});

test("user route mints the same constrained token without a notebook lookup", async () => {
  const { handle, requests } = userRouteHandler();

  const response = await handle(signedInUserEvent);

  assert.equal(response.statusCode, 200);
  assert.deepEqual(JSON.parse(response.body), {
    status: "ready",
    sessionToken: "auth_tokens/temporary-token",
    expiresAt: "2026-09-06T16:30:00.000Z",
    newSessionExpiresAt: "2026-09-06T16:10:00.000Z",
    model: "gemini-3.1-flash-live-preview",
  });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "https://generativelanguage.googleapis.com/v1beta/auth_tokens");
  assert.equal(requests.some((request) => request.url.includes("supabase")), false);
  assert.deepEqual(JSON.parse(requests[0].options.body), {
    uses: 1,
    expireTime: "2026-09-06T16:30:00.000Z",
    newSessionExpireTime: "2026-09-06T16:10:00.000Z",
    fieldMask: "model,generationConfig.responseModalities",
    bidiGenerateContentSetup: {
      model: "models/gemini-3.1-flash-live-preview",
      generationConfig: { responseModalities: ["AUDIO"] },
    },
  });
  assert.equal(response.body.includes("permanent-test-key"), false);
});

test("user route honours a configured start window", async () => {
  const { handle, requests } = userRouteHandler({ userStartWindowSeconds: "300" });

  const response = await handle(signedInUserEvent);

  assert.equal(JSON.parse(response.body).newSessionExpiresAt, "2026-09-06T16:05:00.000Z");
  assert.equal(
    JSON.parse(requests[0].options.body).newSessionExpireTime,
    "2026-09-06T16:05:00.000Z",
  );
});

test("user route never lets the start window outlive the token", async () => {
  const { handle } = userRouteHandler({ userStartWindowSeconds: "999999" });

  const body = JSON.parse((await handle(signedInUserEvent)).body);

  assert.equal(body.newSessionExpiresAt, "2026-09-06T16:30:00.000Z");
  assert.equal(body.newSessionExpiresAt <= body.expiresAt, true);
});

test("start window defaults to 600 s and clamps to 60..1800 s", () => {
  assert.equal(resolveUserStartWindowSeconds(undefined), 600);
  assert.equal(resolveUserStartWindowSeconds(""), 600);
  assert.equal(resolveUserStartWindowSeconds("  "), 600);
  assert.equal(resolveUserStartWindowSeconds("not-a-number"), 600);
  assert.equal(resolveUserStartWindowSeconds("900"), 900);
  assert.equal(resolveUserStartWindowSeconds(120.4), 120);
  assert.equal(resolveUserStartWindowSeconds("5"), 60);
  assert.equal(resolveUserStartWindowSeconds("-100"), 60);
  assert.equal(resolveUserStartWindowSeconds("1800"), 1800);
  assert.equal(resolveUserStartWindowSeconds("7200"), 1800);
});

test("notebook route keeps its 60 s window whatever the user window is", async () => {
  const requests = [];
  const handle = createLiveSessionHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    now: () => new Date("2026-09-06T16:00:00.000Z"),
    userStartWindowSeconds: "1200",
    getPermanentCredential: async () => "permanent-test-key",
    fetchImpl: async (url, options) => {
      requests.push({ url: String(url), options });
      return requests.length === 1
        ? { ok: true, json: async () => [{ id: "8e03b8f4-4f20-4df3-8398-d854adc32b14" }] }
        : { ok: true, json: async () => ({ name: "auth_tokens/temporary-token" }) };
    },
  });

  const response = await handle({
    ...signedInUserEvent,
    pathParameters: { notebookId: "8e03b8f4-4f20-4df3-8398-d854adc32b14" },
  });

  assert.equal(response.statusCode, 200);
  assert.equal(JSON.parse(response.body).newSessionExpiresAt, "2026-09-06T16:01:00.000Z");
  assert.equal(requests.length, 2);
  assert.match(requests[0].url, /\/rest\/v1\/notebooks/);
});

test("notebook route still rejects a malformed notebook id", async () => {
  const { handle, requests } = userRouteHandler();

  const response = await handle({
    ...signedInUserEvent,
    pathParameters: { notebookId: "not-a-uuid" },
  });

  assert.equal(response.statusCode, 400);
  assert.deepEqual(JSON.parse(response.body), { error: "invalidRequest" });
  assert.equal(requests.length, 0);
});
