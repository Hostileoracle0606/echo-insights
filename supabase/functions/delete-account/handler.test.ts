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

// ---- Task 1 reviewer extras ----

Deno.test("iat exactly 300s old accepted, 301s old rejected", async () => {
  const ok = harness();
  assertEquals((await ok.call({ auth: freshJwt(300) })).status, 200);
  const stale = harness();
  assertEquals((await stale.call({ auth: freshJwt(301) })).status, 401);
  assertEquals(stale.deleted, []);
});

function customHarness(client: AdminClient) {
  return createHandler({ admin: () => client, now: () => NOW_MS, log: () => {} });
}
const post = (h: (r: Request) => Promise<Response>, token: string, body: unknown = {}) =>
  h(new Request("http://local/delete-account", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  }));

Deno.test("getUser throwing -> 500, nothing deleted", async () => {
  const deleted: string[] = [];
  const h = customHarness({
    auth: {
      getUser: () => Promise.reject(new Error("net")),
      admin: { deleteUser: (id) => { deleted.push(id); return Promise.resolve({ error: null }); } },
    },
  });
  const res = await post(h, freshJwt());
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { deleted: false });
  assertEquals(deleted, []);
});

Deno.test("id is derived from the token's sub: other token deletes the other id", async () => {
  const deleted: string[] = [];
  const subOf = (t: string) => JSON.parse(atob(t.split(".")[1].replaceAll("-", "+").replaceAll("_", "/"))).sub;
  const h = customHarness({
    auth: {
      getUser: (t) => Promise.resolve({ data: { user: { id: subOf(t) } }, error: null }),
      admin: { deleteUser: (id) => { deleted.push(id); return Promise.resolve({ error: null }); } },
    },
  });
  await post(h, freshJwt());
  await post(h, jwt({ sub: "user-2", iat: NOW_MS / 1000 - 5 }), { user_id: "user-1" });
  assertEquals(deleted, [USER_ID, "user-2"]);
});

// ---- Task 2: Apple ----

function appleHarness(opts: {
  apple?: boolean;
  revoke?: (p: { code: string | undefined }) => Promise<boolean>;
  noRevokeDep?: boolean;
} = {}) {
  const order: string[] = [];
  const codes: (string | undefined)[] = [];
  const logs: Record<string, unknown>[] = [];
  const client: AdminClient = {
    auth: {
      getUser: () =>
        Promise.resolve({
          data: { user: { id: USER_ID, identities: opts.apple === false ? [{ provider: "email" }] : [{ provider: "apple" }] } },
          error: null,
        }),
      admin: { deleteUser: () => { order.push("delete"); return Promise.resolve({ error: null }); } },
    },
  };
  const handler = createHandler({
    admin: () => client,
    now: () => NOW_MS,
    log: (f) => logs.push(f),
    revokeApple: opts.noRevokeDep ? undefined : (p) => {
      order.push("revoke");
      codes.push(p.code);
      return opts.revoke ? opts.revoke(p) : Promise.resolve(true);
    },
  });
  const run = async (body: unknown = { apple_authorization_code: "CODE-X" }) => {
    const res = await post(handler, freshJwt(), body);
    return { status: res.status, body: await res.json() };
  };
  return { run, order, codes, logs };
}

Deno.test("apple user: revoke called before deleteUser, with the body's code", async () => {
  const h = appleHarness();
  const r = await h.run();
  assertEquals(r.body, { deleted: true, apple_revoked: true });
  assertEquals(h.order, ["revoke", "delete"]);
  assertEquals(h.codes, ["CODE-X"]);
});

Deno.test("non-apple user: revoke never called, apple_revoked null", async () => {
  const h = appleHarness({ apple: false });
  const r = await h.run();
  assertEquals(r.body, { deleted: true, apple_revoked: null });
  assertEquals(h.order, ["delete"]);
});

Deno.test("apple failure retried once then deletes anyway with apple_revoked:false", async () => {
  const h = appleHarness({ revoke: () => Promise.resolve(false) });
  const r = await h.run();
  assertEquals(r.status, 200);
  assertEquals(r.body, { deleted: true, apple_revoked: false });
  assertEquals(h.order, ["revoke", "revoke", "delete"]);
});

Deno.test("apple retry succeeding on second attempt -> true", async () => {
  let n = 0;
  const h = appleHarness({ revoke: () => Promise.resolve(++n === 2) });
  assertEquals((await h.run()).body, { deleted: true, apple_revoked: true });
});

Deno.test("missing code -> delete proceeds, apple_revoked:false", async () => {
  const h = appleHarness({ revoke: (p) => Promise.resolve(p.code !== undefined) });
  const r = await h.run({});
  assertEquals(r.body, { deleted: true, apple_revoked: false });
  assertEquals(h.order.at(-1), "delete");
});

Deno.test("missing apple config (no revokeApple dep) -> delete proceeds, apple_revoked:false", async () => {
  const h = appleHarness({ noRevokeDep: true });
  const r = await h.run();
  assertEquals(r.body, { deleted: true, apple_revoked: false });
  assertEquals(h.order, ["delete"]);
});

Deno.test("a thrown revoke does not block deletion and is not logged verbatim", async () => {
  const h = appleHarness({ revoke: () => Promise.reject(new Error("secret-body CODE-X")) });
  const r = await h.run();
  assertEquals(r.body, { deleted: true, apple_revoked: false });
  assertEquals(h.order, ["revoke", "revoke", "delete"]);
  const dump = JSON.stringify(h.logs);
  assert(!dump.includes("CODE-X") && !dump.includes("secret-body"));
});

Deno.test("body is read only for apple_authorization_code (non-string ignored)", async () => {
  const h = appleHarness();
  await h.run({ apple_authorization_code: 123, user_id: "victim" });
  assertEquals(h.codes, []); // no usable code: revoke not attempted
});
