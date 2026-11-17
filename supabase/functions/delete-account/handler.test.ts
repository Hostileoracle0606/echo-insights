import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createHandler, type AdminClient } from "./handler.ts";

const NOW_MS = 1_800_000_000_000;
const USER_ID = "user-1";

const b64url = (o: unknown) =>
  btoa(JSON.stringify(o)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
const jwt = (payload: Record<string, unknown>) =>
  `${b64url({ alg: "HS256", typ: "JWT" })}.${b64url(payload)}.sig-secret-part`;
const freshJwt = (ageSec = 10) => jwt({ sub: USER_ID, iat: NOW_MS / 1000 - ageSec });

function harness(opts: { getUserError?: boolean; deleteError?: boolean } = {}) {
  const deleted: string[] = [];
  const logs: Record<string, unknown>[] = [];
  const client: AdminClient = {
    auth: {
      getUser: () =>
        Promise.resolve(
          opts.getUserError
            ? { data: { user: null }, error: { message: "invalid JWT" } }
            : { data: { user: { id: USER_ID } }, error: null },
        ),
      admin: {
        deleteUser: (id: string) => {
          deleted.push(id);
          return Promise.resolve({ error: opts.deleteError ? { message: "boom" } : null });
        },
      },
    },
  };
  const handler = createHandler({
    admin: () => client,
    now: () => NOW_MS,
    log: (f) => logs.push(f),
  });
  const call = async (init: { method?: string; auth?: string; body?: unknown } = {}) => {
    const headers: Record<string, string> = {};
    if (init.auth) headers.Authorization = `Bearer ${init.auth}`;
    const method = init.method ?? "POST";
    const res = await handler(
      new Request("http://local/delete-account", {
        method,
        headers,
        body: method === "GET" ? undefined : JSON.stringify(init.body ?? {}),
      }),
    );
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  return { call, deleted, logs };
}

Deno.test("no Authorization header -> 401, deleteUser not called", async () => {
  const h = harness();
  const r = await h.call();
  assertEquals(r.status, 401);
  assertEquals(r.body, { error: "unauthorized" });
  assertEquals(h.deleted, []);
});

Deno.test("forged JWT (getUser returns error) -> 401, not called", async () => {
  const h = harness({ getUserError: true });
  const r = await h.call({ auth: freshJwt() });
  assertEquals(r.status, 401);
  assertEquals(h.deleted, []);
});

Deno.test("stale JWT (iat 6 min old, validly accepted by getUser) -> 401", async () => {
  const h = harness();
  const r = await h.call({ auth: freshJwt(6 * 60) });
  assertEquals(r.status, 401);
  assertEquals(r.body, { error: "unauthorized" });
  assertEquals(h.deleted, []);
});

Deno.test("malformed JWT payload -> 401, not called", async () => {
  const h = harness();
  const r = await h.call({ auth: "not.a-jwt.x" });
  assertEquals(r.status, 401);
  assertEquals(h.deleted, []);
});

Deno.test("happy path deletes exactly the JWT's user and returns 200", async () => {
  const h = harness();
  const r = await h.call({ auth: freshJwt() });
  assertEquals(r.status, 200);
  assertEquals(r.body, { deleted: true, apple_revoked: null });
  assertEquals(h.deleted, [USER_ID]);
});

Deno.test("body naming another user id is ignored", async () => {
  const h = harness();
  const r = await h.call({
    auth: freshJwt(),
    body: { user_id: "victim", userId: "victim", id: "victim" },
  });
  assertEquals(r.status, 200);
  assertEquals(h.deleted, [USER_ID]);
});

Deno.test("deleteUser error -> 500 and deleted:false", async () => {
  const h = harness({ deleteError: true });
  const r = await h.call({ auth: freshJwt() });
  assertEquals(r.status, 500);
  assertEquals(r.body, { deleted: false });
});

Deno.test("non-POST -> 405", async () => {
  const h = harness();
  const r = await h.call({ method: "GET", auth: freshJwt() });
  assertEquals(r.status, 405);
  assertEquals(h.deleted, []);
});

Deno.test("logs contain no token", async () => {
  const h = harness();
  const token = freshJwt();
  await h.call({ auth: token });
  await h.call({ auth: freshJwt(6 * 60) });
  const dump = JSON.stringify(h.logs);
  assert(h.logs.length > 0);
  assert(!dump.includes(token));
  assert(!dump.includes("sig-secret-part"));
  assert(!dump.includes("Bearer"));
});
