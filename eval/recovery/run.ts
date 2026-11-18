// Recovery fault matrix: `npm run eval:recovery`. Local Supabase only.
// Every fault × 10 seeds, a fresh test user each, against the real database
// and the real extraction and brief Lambdas run in-process. The model is a
// stub: recovery measures persistence, so no provider is called (and a guard
// counts any request that tries to leave the machine; it must read 0).
import { execFileSync } from "node:child_process";
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { createSupabaseAuthorizer } from "../../infra/lambda/supabase-authorizer/core.mjs";
import { createExtractGraphHandler } from "../../infra/lambda/extract-graph/core.mjs";
import { createSessionBriefHandler } from "../../infra/lambda/close-session/brief.mjs";
import { gatewayInvoke, memoryClaimStore, recordingFetch } from "../privacy/probes/lambdas.mjs";
import { auditUser } from "./audit.mjs";
import fixtures from "./fixtures/patches.json";
import { localStack } from "./local.mjs";
import { FAULTS, runFault, type FaultResult, type ScenarioEnv } from "./scenarios";
import { summarize } from "./summary.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SEEDS = Number(process.env.RECOVERY_SEEDS ?? 10);
const ONLY = process.env.RECOVERY_FAULTS?.split(",").filter(Boolean);

const stack = localStack(process.env);
if (!stack) {
  console.error("recovery eval: source eval/privacy/local-env.sh first (local Supabase only)");
  process.exit(2);
}

// ── Provider stub and the guard that proves nothing left the machine ──────────
const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]", "::1"]);
let realProviderCalls = 0;
const guardedFetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  if (!LOOPBACK.has(new URL(String(input)).hostname)) {
    realProviderCalls += 1;
    throw new TypeError("recovery eval: request to a non-local host refused");
  }
  return fetch(input, init);
}) as typeof fetch;

const extractCallsByText = new Map<string, number>();
const turnTexts = Object.values(fixtures.turns);
const json = (value: unknown) =>
  new Response(JSON.stringify(value), { status: 200, headers: { "content-type": "application/json" } });

function stubProvider(url: string, init?: RequestInit): Response {
  const body = String(init?.body ?? "");
  if (url.includes("-tts:")) {
    // 0.1 s of PCM16 silence.
    const data = Buffer.alloc(4800).toString("base64");
    return json({ candidates: [{ content: { parts: [{ inlineData: { mimeType: "audio/L16;codec=pcm;rate=24000", data } }] } }] });
  }
  if (body.includes("write_session_brief")) {
    return json({ candidates: [{ content: { parts: [{ functionCall: { name: "write_session_brief", args: fixtures.brief } }] } }] });
  }
  const turn = turnTexts.find((t) => body.includes(t.text));
  if (!turn) return new Response('{"error":{"code":503}}', { status: 503 });
  extractCallsByText.set(turn.text, (extractCallsByText.get(turn.text) ?? 0) + 1);
  return json({ candidates: [{ content: { parts: [{ functionCall: { name: "extract_graph", args: { supersedes: [], ...turn.patch } } }] } }] });
}

const lambdaFetch = recordingFetch({ supabaseUrl: stack.url, realFetch: guardedFetch, providerResponder: stubProvider });
const noSleep = async () => {};
const deps = {
  supabaseUrl: stack.url,
  publishableKey: stack.anonKey,
  fetchImpl: lambdaFetch.fetchImpl,
  getPermanentCredential: async () => "recovery-eval-stub-credential",
};
const authorize = createSupabaseAuthorizer(deps);
// One claim store for the whole run: it stands in for DynamoDB, which outlives
// any client process.
const handlers: Record<string, (event: unknown) => Promise<{ statusCode: number; body: string }>> = {
  extractions: createExtractGraphHandler({ ...deps, ...memoryClaimStore(), sleep: noSleep }),
  brief: createSessionBriefHandler({ ...deps, sleep: noSleep, log: () => {} }),
};

const created: string[] = [];
async function rows(table: string, userId: string): Promise<string[]> {
  const found = (await stack!.call(`/rest/v1/${table}?select=text&user_id=eq.${userId}`)) as { text: string }[];
  return found.map((r) => r.text);
}

const env: ScenarioEnv = {
  supabaseUrl: stack.url,
  anonKey: stack.anonKey,
  realFetch: guardedFetch,
  async newUser() {
    const user = await stack!.createUser(created);
    const notebook = await stack!.insert("notebooks", {
      user_id: user.id,
      title: "Recovery eval",
      started_at: new Date().toISOString(),
      conversation_mode: "just_talk",
    });
    return { userId: user.id, token: user.token, notebookId: notebook.id };
  },
  async cleanupUser(userId) {
    await stack!.deleteUser(userId);
  },
  async gateway(route, event) {
    const handler = handlers[route];
    if (!handler) return { statusCode: 404, body: '{"message":"Not Found"}' };
    return gatewayInvoke({ authorize, handler, event });
  },
  audit: (userId) => auditUser({ url: stack!.url, adminHeaders: stack!.admin, userId }),
  async texts(userId) {
    return { journal: await rows("journal_entries", userId), turns: await rows("conversation_turns", userId) };
  },
  providerCalls: () => ({ real: realProviderCalls, stub: lambdaFetch.providerCalls() }),
  extractCalls: (text) => extractCallsByText.get(text) ?? 0,
};

// The Lambdas log ids and counts; keep the run output to progress lines.
const quiet = async <T>(work: () => Promise<T>): Promise<T> => {
  const original = { log: console.log, info: console.info, warn: console.warn };
  console.log = console.info = console.warn = () => {};
  try {
    return await work();
  } finally {
    Object.assign(console, original);
  }
};

const startedAt = new Date().toISOString();
const sha = execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: root }).toString().trim();
const leftoverAtStart = await stack.sweep();
const runs: (FaultResult | { fault: string; seed: number; outcome: "error"; pass: false; error: string })[] = [];

for (const fault of FAULTS.filter((f) => !ONLY || ONLY.includes(f))) {
  for (let seed = 1; seed <= SEEDS; seed += 1) {
    try {
      const result = await quiet(() => runFault(fault, seed, env));
      runs.push(result);
      console.log(
        `${fault} seed=${seed} ${result.variant}: ${result.outcome} partial=${result.partial_turn} ` +
          `kept=${result.completed_turns_kept.n}/${result.completed_turns_kept.of} ` +
          `dups=${Object.values(result.duplicates).reduce((a, b) => a + b, 0)} resumed=${result.resumed}`,
      );
    } catch (error) {
      const message = String((error as Error)?.message ?? error).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, "<jwt>").slice(0, 200);
      runs.push({ fault, seed, outcome: "error", pass: false, error: message });
      console.log(`${fault} seed=${seed}: error ${message}`);
    }
  }
}

let cleanupFailed = false;
for (const id of created) {
  try {
    await stack.deleteUser(id);
  } catch {
    cleanupFailed = true;
  }
}
const leftoverAtEnd = (await stack.leftoverUsers()).length;

const report = {
  version: 1,
  target: "local",
  commit: sha,
  startedAt,
  finishedAt: new Date().toISOString(),
  method: {
    seeds: SEEDS,
    turnsPerScenario: 3,
    faultOn: "turn 2",
    client: "src/lib/turn-state reducer + pipeline + web adapter, mergeExtraction, commitNotebook (real code, vite-node)",
    extraction: "infra/lambda/extract-graph handler in-process behind the real authorizer; in-memory claim store",
    brief: "infra/lambda/close-session brief handler, request version 1",
    provider: "stubbed: synthetic patches from eval/recovery/fixtures/patches.json; no model is called",
  },
  notes: {
    providerRealCalls: realProviderCalls,
    providerStubCalls: lambdaFetch.providerCalls(),
    leftoverUsersAtStart: leftoverAtStart,
    leftoverUsersAtEnd: leftoverAtEnd,
    cleanupFailed,
    migrationsHead: readdirSync(resolve(root, "supabase/migrations")).sort().at(-1)!.replace(/\.sql$/, ""),
  },
  summary: summarize(runs),
  runs,
};

const serialized = JSON.stringify(report, null, 2);
if (/@example\.test|eyJ[A-Za-z0-9_-]{8,}/.test(serialized)) throw new Error("report contains forbidden content");
const out = resolve(root, `eval/results/${startedAt.slice(0, 10)}-${sha}/recovery.json`);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, `${serialized}\n`);

console.log(`\n${relative(root, out)}`);
for (const [fault, s] of Object.entries(report.summary.faults)) {
  console.log(`${fault.padEnd(20)} pass ${s.pass}/${s.runs}  fail ${s.fail}  not_triggered ${s.not_triggered}  error ${s.error}`);
}
console.log(`provider calls: real ${realProviderCalls}, stub ${lambdaFetch.providerCalls()}`);
process.exit(realProviderCalls === 0 && report.summary.total.pass === report.summary.total.runs && !cleanupFailed && leftoverAtEnd === 0 ? 0 : 1);
