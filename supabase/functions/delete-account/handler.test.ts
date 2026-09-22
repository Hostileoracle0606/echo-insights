import { assertEquals } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import { type DeleteAccountDeps, handleDeleteAccount } from "./handler.ts";

function deps(overrides: Partial<DeleteAccountDeps> = {}) {
  const deleted: string[] = [];
  const d: DeleteAccountDeps = {
    verifiedUserId: (auth) => Promise.resolve(auth === "Bearer good" ? "user-from-jwt" : null),
    deleteUser: (id) => {
      deleted.push(id);
      return Promise.resolve({ error: null });
    },
    ...overrides,
  };
  return { d, deleted };
}

const post = (headers: Record<string, string> = {}, body?: string) =>
  new Request("http://localhost/delete-account", { method: "POST", headers, body });

Deno.test("deletes the user named by the verified JWT", async () => {
  const { d, deleted } = deps();
  const res = await handleDeleteAccount(post({ Authorization: "Bearer good" }), d);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { deleted: true });
  assertEquals(deleted, ["user-from-jwt"]);
});

Deno.test("ignores any user id in the request body", async () => {
  const { d, deleted } = deps();
  const res = await handleDeleteAccount(
    post({ Authorization: "Bearer good" }, JSON.stringify({ userId: "someone-else", sub: "someone-else" })),
    d,
  );
  assertEquals(res.status, 200);
  assertEquals(deleted, ["user-from-jwt"]);
});

Deno.test("rejects a missing authorization header without deleting", async () => {
  const { d, deleted } = deps();
  const res = await handleDeleteAccount(post(), d);
  assertEquals(res.status, 401);
  assertEquals(deleted, []);
});

Deno.test("rejects an invalid or throwing token check without deleting", async () => {
  const bad = deps();
  assertEquals((await handleDeleteAccount(post({ Authorization: "Bearer bad" }), bad.d)).status, 401);
  assertEquals(bad.deleted, []);

  const throwing = deps({ verifiedUserId: () => Promise.reject(new Error("auth down")) });
  assertEquals((await handleDeleteAccount(post({ Authorization: "Bearer good" }), throwing.d)).status, 401);
  assertEquals(throwing.deleted, []);
});

Deno.test("reports a failed admin delete as 500 without leaking detail", async () => {
  const { d } = deps({ deleteUser: () => Promise.resolve({ error: new Error("db: secret detail") }) });
  const res = await handleDeleteAccount(post({ Authorization: "Bearer good" }), d);
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { error: "delete failed" });
});

Deno.test("only POST deletes; OPTIONS answers CORS preflight", async () => {
  const { d, deleted } = deps();
  const get = new Request("http://localhost/delete-account", { headers: { Authorization: "Bearer good" } });
  assertEquals((await handleDeleteAccount(get, d)).status, 405);
  const pre = await handleDeleteAccount(new Request("http://localhost/delete-account", { method: "OPTIONS" }), d);
  assertEquals(pre.status, 200);
  assertEquals(pre.headers.get("Access-Control-Allow-Origin"), "*");
  assertEquals(deleted, []);
});
