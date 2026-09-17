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
