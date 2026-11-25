import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createHandler, type AdminClient, type Deps } from "./handler.ts";

const NOW_MS = 1_800_000_000_000;
const USER_ID = "user-1";
const REQ = "7b0f6c0e-3f4a-4a52-9d5e-1c2b3a4d5e6f";

const b64url = (o: unknown) =>
  btoa(JSON.stringify(o)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
const jwt = (payload: Record<string, unknown>) =>
  `${b64url({ alg: "HS256", typ: "JWT" })}.${b64url(payload)}.sig-secret-part`;
const freshJwt = (ageSec = 10) => jwt({ sub: USER_ID, iat: NOW_MS / 1000 - ageSec });

type Queue = Deps["queue"];

interface Opts {
  getUserError?: boolean;
  identities?: { provider: string }[];
  insertResult?: "inserted" | "exists";
  insertThrows?: boolean;
  findThrows?: boolean;
  /** request ids already queued, as "user|request" keys */
  preQueued?: string[];
  revoke?: (p: { code: string | undefined }) => Promise<boolean>;
  noRevokeDep?: boolean;
}

function harness(opts: Opts = {}) {
  const order: string[] = [];
  const inserts: string[] = [];
  const finds: string[] = [];
  const codes: (string | undefined)[] = [];
  const logs: Record<string, unknown>[] = [];
  const stored = new Set(opts.preQueued ?? []);
  // No admin.deleteUser on purpose: the handler must never need it.
  const client = {
    auth: {
      getUser: () =>
        Promise.resolve(
          opts.getUserError
            ? { data: { user: null }, error: { message: "invalid JWT" } }
            : { data: { user: { id: USER_ID, identities: opts.identities } }, error: null },
        ),
    },
  } as unknown as AdminClient;
  const queue: Queue = {
    find: (u, r) => {
      order.push("find");
      finds.push(`${u}|${r}`);
      if (opts.findThrows) return Promise.reject(new Error("db"));
      return Promise.resolve(stored.has(`${u}|${r}`));
    },
    insert: (u, r) => {
      order.push("insert");
      inserts.push(`${u}|${r}`);
      if (opts.insertThrows) return Promise.reject(new Error("db"));
      const res = opts.insertResult ?? (stored.has(`${u}|${r}`) ? "exists" : "inserted");
      if (res === "inserted") stored.add(`${u}|${r}`);
      return Promise.resolve(res);
    },
  };
  const handler = createHandler({
    admin: () => client,
    queue,
    now: () => NOW_MS,
    log: (f) => logs.push(f),
    revokeApple: opts.noRevokeDep ? undefined : (p) => {
      order.push("revoke");
      codes.push(p.code);
      return opts.revoke ? opts.revoke(p) : Promise.resolve(true);
    },
  });
  const call = async (
    init: { method?: string; auth?: string; body?: unknown; raw?: string } = {},
  ) => {
    const headers: Record<string, string> = {};
    if (init.auth) headers.Authorization = `Bearer ${init.auth}`;
    const method = init.method ?? "POST";
    const res = await handler(
      new Request("http://local/delete-account", {
        method,
        headers,
        body: method === "GET" ? undefined : (init.raw ?? JSON.stringify(init.body ?? {})),
      }),
    );
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const ok = (body: Record<string, unknown> = {}) =>
    call({ auth: freshJwt(), body: { request_id: REQ, ...body } });
  return { call, ok, order, inserts, finds, codes, logs, stored };
}

const appleUser = { identities: [{ provider: "apple" }] };

Deno.test("no Authorization header -> 401, nothing queued", async () => {
  const h = harness();
  const r = await h.call({ body: { request_id: REQ } });
  assertEquals(r.status, 401);
  assertEquals(r.body, { error: "unauthorized" });
  assertEquals(h.order, []);
});

Deno.test("forged JWT (getUser returns error) -> 401, nothing queued", async () => {
  const h = harness({ getUserError: true });
  const r = await h.ok();
  assertEquals(r.status, 401);
  assertEquals(h.order, []);
});

Deno.test("stale JWT (iat 6 min old, validly accepted by getUser) -> 401", async () => {
  const h = harness();
  const r = await h.call({ auth: freshJwt(6 * 60), body: { request_id: REQ } });
  assertEquals(r.status, 401);
  assertEquals(r.body, { error: "unauthorized" });
  assertEquals(h.order, []);
});

Deno.test("malformed JWT payload -> 401, nothing queued", async () => {
  const h = harness();
  const r = await h.call({ auth: "not.a-jwt.x", body: { request_id: REQ } });
  assertEquals(r.status, 401);
  assertEquals(h.order, []);
});

Deno.test("iat exactly 300s old accepted, 301s old rejected", async () => {
  const ok = harness();
  assertEquals((await ok.call({ auth: freshJwt(300), body: { request_id: REQ } })).status, 200);
  const stale = harness();
  assertEquals((await stale.call({ auth: freshJwt(301), body: { request_id: REQ } })).status, 401);
  assertEquals(stale.inserts, []);
});

Deno.test("non-POST -> 405", async () => {
  const h = harness();
  const r = await h.call({ method: "GET", auth: freshJwt() });
  assertEquals(r.status, 405);
  assertEquals(h.order, []);
});

Deno.test("valid JWT + request_id queues exactly the JWT's user (body user_id ignored)", async () => {
  const h = harness();
  const r = await h.ok({ user_id: "victim", userId: "victim", id: "victim" });
  assertEquals(r.status, 200);
  assertEquals(r.body, { queued: true, already_queued: false, apple_revoked: null });
  assertEquals(h.inserts, [`${USER_ID}|${REQ}`]);
});

Deno.test("missing or non-uuid request_id -> 400, nothing queued, no Apple call", async () => {
  for (const body of [{}, { request_id: 5 }, { request_id: "nope" }, { request_id: "" }]) {
    const h = harness(appleUser);
    const r = await h.call({ auth: freshJwt(), body: { ...body, apple_authorization_code: "C" } });
    assertEquals(r.status, 400);
    assertEquals(r.body, { error: "bad_request" });
    assertEquals(h.order, []);
  }
  const h = harness();
  const r = await h.call({ auth: freshJwt(), raw: "not json" });
  assertEquals(r.status, 400);
  assertEquals(h.order, []);
});

Deno.test("same request_id again -> already_queued:true, Apple not called again, no second insert", async () => {
  const h = harness(appleUser);
  const first = await h.ok({ apple_authorization_code: "CODE-X" });
  assertEquals(first.body, { queued: true, already_queued: false, apple_revoked: true });
  const second = await h.ok({ apple_authorization_code: "CODE-Y" });
  assertEquals(second.status, 200);
  assertEquals(second.body, { queued: true, already_queued: true, apple_revoked: false });
  assertEquals(h.codes, ["CODE-X"]);
  assertEquals(h.inserts.length, 1);
});

Deno.test("a request already queued is found BEFORE Apple is called", async () => {
  const h = harness({ ...appleUser, preQueued: [`${USER_ID}|${REQ}`] });
  const r = await h.ok({ apple_authorization_code: "CODE-X" });
  assertEquals(r.body, { queued: true, already_queued: true, apple_revoked: false });
  assertEquals(h.order, ["find"]);
});

Deno.test("insert race returning exists -> already_queued:true", async () => {
  const h = harness({ insertResult: "exists" });
  const r = await h.ok();
  assertEquals(r.status, 200);
  assertEquals(r.body, { queued: true, already_queued: true, apple_revoked: null });
});

Deno.test("apple user: revoke runs before the insert, once, with the body's code", async () => {
  const h = harness(appleUser);
  const r = await h.ok({ apple_authorization_code: "CODE-X" });
  assertEquals(r.body, { queued: true, already_queued: false, apple_revoked: true });
  assertEquals(h.order, ["find", "revoke", "insert"]);
  assertEquals(h.codes, ["CODE-X"]);
});

Deno.test("non-apple user: revoke never called, apple_revoked null", async () => {
  const h = harness({ identities: [{ provider: "email" }] });
  const r = await h.ok({ apple_authorization_code: "CODE-X" });
  assertEquals(r.body, { queued: true, already_queued: false, apple_revoked: null });
  assertEquals(h.order, ["find", "insert"]);
});

Deno.test("Apple failure still queues with apple_revoked:false (handler never re-calls)", async () => {
  const h = harness({ ...appleUser, revoke: () => Promise.resolve(false) });
  const r = await h.ok({ apple_authorization_code: "CODE-X" });
  assertEquals(r.status, 200);
  assertEquals(r.body, { queued: true, already_queued: false, apple_revoked: false });
  assertEquals(h.order, ["find", "revoke", "insert"]);
  assertEquals(h.logs.some((l) => l.event === "apple_revoke" && l.stage === "failed"), true);
});

Deno.test("Apple retry after a lost failure reply still prompts manual removal", async () => {
  const h = harness({ ...appleUser, revoke: () => Promise.resolve(false) });
  await h.ok({ apple_authorization_code: "CODE-X" });
  const retry = await h.ok();
  assertEquals(retry.body, { queued: true, already_queued: true, apple_revoked: false });
  assertEquals(h.codes, ["CODE-X"]);
  assertEquals(h.inserts.length, 1);
});

Deno.test("missing code / missing apple config -> queued, apple_revoked:false", async () => {
  const a = harness({ ...appleUser, revoke: (p) => Promise.resolve(p.code !== undefined) });
  const ra = await a.ok();
  assertEquals(ra.body, { queued: true, already_queued: false, apple_revoked: false });
  assertEquals(a.logs.some((l) => l.event === "apple_revoke" && l.stage === "no_code"), true);
  const b = harness({ ...appleUser, noRevokeDep: true });
  const rb = await b.ok({ apple_authorization_code: "C" });
  assertEquals(rb.body, { queued: true, already_queued: false, apple_revoked: false });
  assertEquals(b.logs.some((l) => l.event === "apple_revoke" && l.stage === "no_config"), true);
});

Deno.test("a thrown revoke still queues and is not logged verbatim", async () => {
  const h = harness({ ...appleUser, revoke: () => Promise.reject(new Error("secret-body CODE-X")) });
  const r = await h.ok({ apple_authorization_code: "CODE-X" });
  assertEquals(r.body, { queued: true, already_queued: false, apple_revoked: false });
  const dump = JSON.stringify(h.logs);
  assert(!dump.includes("CODE-X") && !dump.includes("secret-body"));
});

Deno.test("non-string apple code is ignored", async () => {
  const h = harness(appleUser);
  await h.ok({ apple_authorization_code: 123 });
  assertEquals(h.codes, []);
});

Deno.test("queue insert error -> 500 queued:false", async () => {
  const h = harness({ insertThrows: true });
  const r = await h.ok();
  assertEquals(r.status, 500);
  assertEquals(r.body, { queued: false });
});

Deno.test("queue find error -> 500 queued:false, Apple not called", async () => {
  const h = harness({ ...appleUser, findThrows: true });
  const r = await h.ok({ apple_authorization_code: "C" });
  assertEquals(r.status, 500);
  assertEquals(r.body, { queued: false });
  assertEquals(h.codes, []);
});

Deno.test("getUser throwing -> 500, nothing queued", async () => {
  const order: string[] = [];
  const h = createHandler({
    admin: () => ({ auth: { getUser: () => Promise.reject(new Error("net")) } }) as unknown as AdminClient,
    queue: {
      find: () => { order.push("find"); return Promise.resolve(false); },
      insert: () => { order.push("insert"); return Promise.resolve("inserted"); },
    },
    now: () => NOW_MS,
    log: () => {},
  });
  const res = await h(new Request("http://local/x", {
    method: "POST",
    headers: { Authorization: `Bearer ${freshJwt()}` },
    body: JSON.stringify({ request_id: REQ }),
  }));
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { queued: false });
  assertEquals(order, []);
});

Deno.test("id is derived from the token's sub", async () => {
  const inserts: string[] = [];
  const subOf = (t: string) =>
    JSON.parse(atob(t.split(".")[1].replaceAll("-", "+").replaceAll("_", "/"))).sub;
  const h = createHandler({
    admin: () => ({
      auth: { getUser: (t: string) => Promise.resolve({ data: { user: { id: subOf(t) } }, error: null }) },
    }) as unknown as AdminClient,
    queue: {
      find: () => Promise.resolve(false),
      insert: (u, r) => { inserts.push(`${u}|${r}`); return Promise.resolve("inserted"); },
    },
    now: () => NOW_MS,
    log: () => {},
  });
  const send = (t: string, body: unknown) =>
    h(new Request("http://local/x", {
      method: "POST",
      headers: { Authorization: `Bearer ${t}` },
      body: JSON.stringify(body),
    }));
  await send(freshJwt(), { request_id: REQ });
  await send(jwt({ sub: "user-2", iat: NOW_MS / 1000 - 5 }), { request_id: REQ, user_id: "user-1" });
  assertEquals(inserts, [`user-1|${REQ}`, `user-2|${REQ}`]);
});

Deno.test("logs contain no token, user id or request id; stages are allowlisted", async () => {
  const h = harness(appleUser);
  const token = freshJwt();
  await h.call({ auth: token, body: { request_id: REQ, apple_authorization_code: "CODE-X" } });
  await h.call({ auth: token, body: { request_id: REQ } }); // already_queued
  await h.call({ auth: freshJwt(6 * 60), body: { request_id: REQ } });
  const dump = JSON.stringify(h.logs);
  assert(h.logs.length > 0);
  assert(!dump.includes(token) && !dump.includes("sig-secret-part") && !dump.includes("Bearer"));
  assert(!dump.includes(REQ) && !dump.includes(USER_ID) && !dump.includes("CODE-X"));
  assertEquals(h.logs.some((l) => l.stage === "queued"), true);
  assertEquals(h.logs.some((l) => l.stage === "already_queued"), true);
});

Deno.test("apple log reason survives safeLog's allowlist", async () => {
  const { sanitizeLogFields } = await import("../_shared/safe-log.ts");
  assertEquals(sanitizeLogFields({ event: "apple_revoke", stage: "no_config", ok: false }), {
    event: "apple_revoke",
    stage: "no_config",
    ok: false,
  });
  assertEquals(sanitizeLogFields({ event: "delete_account", stage: "already_queued", ok: true }), {
    event: "delete_account",
    stage: "already_queued",
    ok: true,
  });
});
