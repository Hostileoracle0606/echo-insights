#!/usr/bin/env node
// Times every network hop the app makes, against a STAGING project, from
// wherever you run it (run it on the same network the phone will use).
//
// Required environment (a test account, never a real user's):
//   SUPABASE_URL, SUPABASE_ANON_KEY       staging project
//   NOTEBOOK_RUNTIME_URL                  staging AWS runtime base URL
//   LUMEN_TEST_EMAIL, LUMEN_TEST_PASSWORD test account with a few notebooks
//   LUMEN_TEST_NOTEBOOK_ID                one of that account's notebooks
//
//   node scripts/latency/probe-staging.mjs [--runs 10] [--with-model] [--allow-production]
//
// The first sample of each hop is reported separately: it includes cold
// starts (edge function, Lambda, the embedding model). `--with-model` also
// times one extraction per run, which calls Gemini and costs a request each.
const PRODUCTION_REF = "bjoevzvsdlhlcjywpyfx";

const args = process.argv.slice(2);
const runs = Number(args[args.indexOf("--runs") + 1]) || 10;
const withModel = args.includes("--with-model");
const env = (name) => {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing ${name}. See the header of this file.`);
    process.exit(2);
  }
  return value.replace(/\/$/, "");
};

const supabaseUrl = env("SUPABASE_URL");
if (supabaseUrl.includes(PRODUCTION_REF) && !args.includes("--allow-production")) {
  console.error("Refusing to probe the live Lumen project. Point SUPABASE_URL at staging, or pass --allow-production.");
  process.exit(2);
}
const anonKey = env("SUPABASE_ANON_KEY");
const runtimeUrl = env("NOTEBOOK_RUNTIME_URL");
const notebookId = env("LUMEN_TEST_NOTEBOOK_ID");

async function timed(fn) {
  const t0 = performance.now();
  const response = await fn();
  const body = await response.text();
  const ms = performance.now() - t0;
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${body.slice(0, 160)}`);
  return { ms, bytes: body.length };
}

async function signIn() {
  const response = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: anonKey, "content-type": "application/json" },
    body: JSON.stringify({ email: env("LUMEN_TEST_EMAIL"), password: env("LUMEN_TEST_PASSWORD") }),
  });
  if (!response.ok) throw new Error(`sign-in failed: HTTP ${response.status}`);
  return (await response.json()).access_token;
}

function hops(token) {
  const auth = { apikey: anonKey, authorization: `Bearer ${token}` };
  const json = { ...auth, "content-type": "application/json" };
  const rest = (path) => () => fetch(`${supabaseUrl}/rest/v1/${path}`, { headers: auth });
  const rpc = (fn, body) => () =>
    fetch(`${supabaseUrl}/rest/v1/rpc/${fn}`, { method: "POST", headers: json, body: JSON.stringify(body) });
  const runtime = (path, body) => () =>
    fetch(`${runtimeUrl}${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  const list = [
    ["auth getUser (authorizer + edge fn do this)", () => fetch(`${supabaseUrl}/auth/v1/user`, { headers: auth })],
    ["rest notebooks list (dashboard)", rest("notebooks?select=*&order=started_at.desc")],
    ["rpc get_notebook_snapshot (open notebook)", rpc("get_notebook_snapshot", { p_notebook_id: notebookId })],
    ["rest conversation_turns 500 (open notebook)",
      rest(`conversation_turns?select=turn_id,speaker,text,spoken_at,input&notebook_id=eq.${notebookId}&order=spoken_at.desc&limit=500`)],
    ["edge retrieve-memory user scope (live recall)", () =>
      fetch(`${supabaseUrl}/functions/v1/retrieve-memory`, {
        method: "POST",
        headers: json,
        body: JSON.stringify({ query: "how was the week", notebookId, scope: "user" }),
      })],
    ["runtime POST /v1/live-sessions (live token)", runtime("/v1/live-sessions")],
    ["runtime POST close (stored card fast path)", runtime(`/v1/notebooks/${notebookId}/close`)],
  ];
  if (withModel) {
    list.push(["runtime POST extractions (Gemini, per turn)", () =>
      runtime(`/v1/notebooks/${notebookId}/extractions`, {
        turnId: `probe-${Date.now()}-${Math.random().toString(36).slice(2)}`,
        extractorVersion: "probe/v1",
        text: "I had coffee with Maya and we talked about the Atlas launch.",
        mode: "granular",
        context: { entities: [], relations: [], recentConversation: [], answeringFollowUp: null },
      })()]);
  }
  return list;
}

const pct = (s, p) => s[Math.min(s.length - 1, Math.ceil(p * s.length) - 1)];

const token = await signIn();
console.log(`Probing ${hops(token).length} hops × ${runs} runs (first run reported as cold)…\n`);
console.log(["hop", "cold", "p50", "p95", "KB"].join("\t"));
for (const [name, fn] of hops(token)) {
  const samples = [];
  let bytes = 0;
  try {
    for (let i = 0; i < runs + 1; i++) {
      const r = await timed(fn);
      samples.push(r.ms);
      bytes = r.bytes;
    }
  } catch (error) {
    console.log(`${name}\tFAILED: ${error.message}`);
    continue;
  }
  const cold = samples.shift();
  samples.sort((a, b) => a - b);
  console.log([name, cold.toFixed(0), pct(samples, 0.5).toFixed(0), pct(samples, 0.95).toFixed(0), (bytes / 1024).toFixed(1)].join("\t"));
}
