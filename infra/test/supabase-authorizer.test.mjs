import assert from "node:assert/strict";
import test from "node:test";

import { createSupabaseAuthorizer } from "../lambda/supabase-authorizer/core.mjs";

test("rejects a request without a Supabase sign-in token", async () => {
  let calledSupabase = false;
  const authorize = createSupabaseAuthorizer({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    fetchImpl: async () => {
      calledSupabase = true;
      throw new Error("should not be called");
    },
  });

  const result = await authorize({ headers: {} });

  assert.deepEqual(result, { isAuthorized: false });
  assert.equal(calledSupabase, false);
});

test("authorizes a valid Supabase user and forwards only their identifier", async () => {
  const authorize = createSupabaseAuthorizer({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    fetchImpl: async () => ({
      ok: true,
      json: async () => ({ id: "user-123", email: "private@example.com" }),
    }),
  });

  const result = await authorize({
    headers: { authorization: "Bearer signed-user-token" },
  });

  assert.deepEqual(result, {
    isAuthorized: true,
    context: { userId: "user-123" },
  });
});

// Results are cached per token (infra-stack.ts), and a deny is cached too:
// Supabase being unreachable must fail the request (500, not cached), not
// lock a valid token out for the cache's lifetime.
function authorizerAnswering(answer) {
  return createSupabaseAuthorizer({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    fetchImpl: answer,
  });
}

const signedIn = { headers: { authorization: "Bearer signed-user-token" } };

test("denies a token Supabase rejects", async () => {
  for (const status of [401, 403]) {
    const authorize = authorizerAnswering(async () => ({
      ok: false,
      status,
      json: async () => ({}),
    }));
    assert.deepEqual(await authorize(signedIn), { isAuthorized: false });
  }
});

test("fails, rather than denies, when Supabase can't answer", async () => {
  for (const status of [429, 500, 503]) {
    const authorize = authorizerAnswering(async () => ({
      ok: false,
      status,
      json: async () => ({}),
    }));
    await assert.rejects(authorize(signedIn), /Supabase/);
  }
  const unreachable = authorizerAnswering(async () => {
    throw new TypeError("fetch failed");
  });
  await assert.rejects(unreachable(signedIn), /Supabase/);
});
