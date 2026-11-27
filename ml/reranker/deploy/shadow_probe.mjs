// Shadow-mode probe for a hosted test project: a throwaway user whose memory is
// synthetic validation histories (plus the eval's background distractors), real
// recall calls to the deployed retrieve-memory, then the user is deleted.
//
//   node ml/reranker/deploy/shadow_probe.mjs <project-ref> <replays-dir> <val-worlds.jsonl> <queries.json> [worlds] [--keep]
//
// Refuses production. Never prints keys or the generated password. The shadow
// scores themselves are in the function's logs (rerank, rerankMs, ...).
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

import { backgroundRows } from "../../../eval/memory/background.mjs";
import { restoreSnapshot } from "../../../eval/memory/snapshot.mjs";

const [ref, replaysDir, worldsFile, queriesFile, count = "8"] = process.argv.slice(2).filter((a) => a !== "--keep");
const keep = process.argv.includes("--keep");
if (!ref || ref === "bjoevzvsdlhlcjywpyfx") throw new Error("shadow_probe: needs a non-production project ref");

const keys = Object.fromEntries(execFileSync("supabase", ["projects", "api-keys", "--project-ref", ref, "-o", "env"], { encoding: "utf8" })
  .split("\n").map((l) => l.match(/^(\w+)="?([^"]*)"?$/)).filter(Boolean).map((m) => [m[1], m[2]]));
const url = `https://${ref}.supabase.co`;
const service = keys.SUPABASE_SERVICE_ROLE_KEY;
const anon = keys.SUPABASE_ANON_KEY;
const adminHeaders = { apikey: service, authorization: `Bearer ${service}`, "content-type": "application/json" };
const call = async (path, init = {}) => {
  const res = await fetch(`${url}${path}`, init);
  const text = await res.text();
  if (!res.ok) throw new Error(`${init.method ?? "GET"} ${path.split("?")[0]} → ${res.status}`);
  return text ? JSON.parse(text) : null;
};

const email = `lumen-shadow-probe-${randomBytes(6).toString("hex")}@example.test`;
const password = `Probe-${randomBytes(12).toString("hex")}-Aa1!`;
const user = await call("/auth/v1/admin/users", { method: "POST", headers: adminHeaders, body: JSON.stringify({ email, password, email_confirm: true }) });
console.log(`probe user created (${email})`);
try {
  const { access_token: token } = await call("/auth/v1/token?grant_type=password", {
    method: "POST", headers: { apikey: anon, "content-type": "application/json" }, body: JSON.stringify({ email, password }) });

  const worldIds = readdirSync(replaysDir).filter((f) => f.endsWith(".json")).sort().slice(0, Number(count)).map((f) => f.replace(/\.json$/, ""));
  const written = new Map(readFileSync(worldsFile, "utf8").trim().split("\n").map((l) => JSON.parse(l)).map((r) => [r.world.id, r.written.queries]));
  const toolQueries = JSON.parse(readFileSync(queriesFile, "utf8"));
  const notebooks = new Map();
  let entityCount = 0;
  for (const id of worldIds) {
    const { snapshot } = JSON.parse(readFileSync(join(replaysDir, `${id}.json`), "utf8"));
    const { notebookId } = await restoreSnapshot({ url, adminHeaders, userId: user.id, snapshot });
    const bg = backgroundRows({ userId: user.id, notebookId });
    await call("/rest/v1/entities", { method: "POST", headers: adminHeaders, body: JSON.stringify(bg.entities) });
    await call("/rest/v1/relations", { method: "POST", headers: adminHeaders, body: JSON.stringify(bg.relations) });
    entityCount += snapshot.tables.entities.length + bg.entities.length;
    notebooks.set(id, notebookId);
  }
  console.log(`seeded ${worldIds.length} synthetic histories, ${entityCount} entities; waiting for embeddings`);

  // Entity inserts trigger embed-entities; wait until the user's records are embedded.
  const started = Date.now();
  let embedded = 0;
  while (Date.now() - started < 300_000) {
    const rows = await call(`/rest/v1/entity_embeddings?select=entity_id&user_id=eq.${user.id}`, { headers: adminHeaders });
    embedded = rows.length;
    if (embedded >= entityCount) break;
    await new Promise((r) => setTimeout(r, 5000));
  }
  console.log(`embedded ${embedded}/${entityCount} in ${Math.round((Date.now() - started) / 1000)} s`);

  const latencies = [];
  let answered = 0;
  for (const id of worldIds) {
    for (const q of written.get(id) ?? []) {
      const query = toolQueries[q.id] ?? q.text;
      const t = performance.now();
      const res = await call("/functions/v1/retrieve-memory", {
        method: "POST", headers: { apikey: anon, authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify({ query, notebookId: notebooks.get(id), scope: "user" }) });
      latencies.push(performance.now() - t);
      if (res.entityIds?.length) answered += 1;
    }
  }
  latencies.sort((a, b) => a - b);
  const p = (f) => Math.round(latencies[Math.min(latencies.length - 1, Math.ceil(latencies.length * f) - 1)]);
  console.log(JSON.stringify({ recalls: latencies.length, withMemory: answered, clientMs: { p50: p(0.5), p95: p(0.95) }, at: new Date().toISOString() }));
} finally {
  if (!keep) {
    await call(`/auth/v1/admin/users/${user.id}`, { method: "DELETE", headers: adminHeaders });
    const left = await call(`/rest/v1/notebooks?select=id&user_id=eq.${user.id}`, { headers: adminHeaders });
    console.log(`probe user deleted; notebooks left: ${left.length}`);
  }
}
