// The recovery fault matrix. Each scenario is three typed turns on a fresh
// user; turn 2 is hit by the fault, then a fresh client restarts from the
// database and the device's turn journal, finishes what it can, and speaks
// turn 3. The audit then reads what actually landed.
import { createClient } from "@supabase/supabase-js";

import { GATEWAY, createEvalClient, deviceStorage, type EvalClient } from "./client";
import { faultyFetch } from "./faults.mjs";
import fixtures from "./fixtures/patches.json";
import { useSupabase } from "./supabase-shim";

export const FAULTS = [
  "extract_before",
  "extract_lost_ack",
  "commit_before",
  "commit_lost_ack",
  "kill_after_journal",
  "kill_after_extract",
  "concurrent_commit",
  "brief_lost_ack",
] as const;
export type FaultName = (typeof FAULTS)[number];

export type PartialTurn = "recovered" | "marked" | "dropped" | "duplicated" | "lost_completed";
export type Outcome = "pass" | "fail" | "not_triggered";

export interface GatewayEvent {
  headers: Record<string, string>;
  pathParameters: { notebookId: string };
  requestContext: Record<string, unknown>;
  body: string | null;
}

export interface ScenarioEnv {
  supabaseUrl: string;
  anonKey: string;
  /** Reaches the database (local Supabase, or a fake in tests). */
  realFetch: typeof fetch;
  newUser: () => Promise<{ userId: string; token: string; notebookId: string }>;
  cleanupUser: (userId: string) => Promise<void>;
  /** The API Gateway routes, answered in-process. */
  gateway: (route: string, event: GatewayEvent) => Promise<{ statusCode: number; body: string }>;
  audit: (userId: string) => Promise<{ counts: Record<string, number>; duplicates: Record<string, number> }>;
  /** Journal entry texts and conversation turn texts the user owns. */
  texts: (userId: string) => Promise<{ journal: string[]; turns: string[] }>;
  /** Cumulative: real = reached a provider host (must stay 0); stub = answered by the stub. */
  providerCalls: () => { real: number; stub: number };
  /** Model calls whose request carried this turn text. */
  extractCalls: (text: string) => number;
}

export interface FaultResult {
  fault: FaultName;
  seed: number;
  variant: string;
  triggered: boolean;
  outcome: Outcome;
  pass: boolean;
  completed_turns_kept: { n: number; of: number };
  partial_turn: PartialTurn;
  duplicates: Record<string, number>;
  counts: Record<string, number>;
  /** Turns the restarted client found in the journal and resumed. */
  resumed: number;
  /** Model calls carrying turn 2's text (the faulted turn). */
  turn2_extractions: number;
  conflicts: number;
  brief?: { first: string; retry: string | null };
  client_errors: number;
  provider_real_calls: number;
  provider_stub_calls: number;
}

type Matcher = "extract" | "commit" | "brief";
interface Plan {
  matcher: Matcher;
  mode: "before" | "lost_ack" | "kill" | "kill_after";
  after: number;
}

const MATCH: Record<Matcher, (url: string) => boolean> = {
  extract: (url) => url.startsWith(GATEWAY) && url.endsWith("/extractions"),
  commit: (url) => url.endsWith("/rest/v1/rpc/commit_notebook"),
  brief: (url) => url.startsWith(GATEWAY) && url.endsWith("/brief"),
};

/** Mulberry32: small, seedable, deterministic. */
function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Turn 1's request is the 1st match, turn 2's the 2nd. Kill scenarios vary
// where in the step the process dies: odd seeds after the server handled the
// request, even seeds before it left.
export function planFor(name: FaultName, seed: number): { plan: Plan | null; variant: string } {
  const kill = seed % 2 === 1 ? "kill_after" : "kill";
  switch (name) {
    case "extract_before":
      return { plan: { matcher: "extract", mode: "before", after: 2 }, variant: "before" };
    case "extract_lost_ack":
      return { plan: { matcher: "extract", mode: "lost_ack", after: 2 }, variant: "lost_ack" };
    case "commit_before":
      return { plan: { matcher: "commit", mode: "before", after: 2 }, variant: "before" };
    case "commit_lost_ack":
      return { plan: { matcher: "commit", mode: "lost_ack", after: 2 }, variant: "lost_ack" };
    case "kill_after_journal":
      return { plan: { matcher: "extract", mode: kill, after: 2 }, variant: kill };
    case "kill_after_extract":
      return { plan: { matcher: "commit", mode: kill, after: 2 }, variant: kill };
    case "concurrent_commit":
      return { plan: null, variant: "two_devices" };
    case "brief_lost_ack":
      return { plan: { matcher: "brief", mode: "lost_ack", after: 1 }, variant: "lost_ack" };
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Routes gateway URLs to the in-process Lambdas; everything else to the database. */
function routerFetch(env: ScenarioEnv): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (!url.startsWith(GATEWAY)) return env.realFetch(input, init);
    const parts = new URL(url).pathname.split("/").filter(Boolean); // v1 notebooks {id} {route}
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    const result = await env.gateway(parts[3], {
      headers,
      pathParameters: { notebookId: parts[2] },
      requestContext: {},
      body: typeof init?.body === "string" ? init.body : null,
    });
    return new Response(result.body, { status: result.statusCode, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
}

/**
 * Waits for `work`; if the fault is a kill, stops waiting once it fired (the
 * process is gone) and lets in-flight side requests settle briefly.
 */
async function untilDoneOrKilled(work: Promise<void>, fault: ReturnType<typeof faultyFetch> | null, killing: boolean) {
  const deadline = Date.now() + 30_000;
  let done = false;
  let failure: unknown = null;
  work.then(() => (done = true), (error) => ((failure = error), (done = true)));
  while (!done && !(killing && fault?.triggered())) {
    if (Date.now() > deadline) throw new Error("scenario step timed out");
    await sleep(5);
  }
  if (failure) throw failure;
  if (!done) await sleep(50);
}

export interface Observed {
  triggered: boolean;
  kept: number;
  of: number;
  partial: PartialTurn;
  duplicateTotal: number;
  /** Turns the restarted client found in the turn journal. */
  resumed: number;
  /** Model calls for turn 2 across the whole run, restart included. */
  turn2Extractions: number;
  conflicts: number;
  brief?: { first: string; retry: string | null };
  stubCalls: number;
}

/**
 * The pass rule, per fault. Nothing lost and nothing twice, always. Beyond
 * that, only the extraction faults may leave turn 2 out of the graph (the
 * spec's "dropped or marked"); every other fault must finish it exactly once,
 * by the route the fault is about: a kill through the journal, a lost commit
 * through a deduplicated retry, a race through a rebase, and a retried close
 * through "unchanged" without a second brief.
 */
export function judge(fault: FaultName, o: Observed): Outcome {
  if (!o.triggered) return "not_triggered";
  if (o.kept < o.of || o.duplicateTotal > 0) return "fail";
  const once = o.partial === "recovered" && o.turn2Extractions === 1;
  switch (fault) {
    case "extract_before":
    case "extract_lost_ack":
      return ["recovered", "marked", "dropped"].includes(o.partial) ? "pass" : "fail";
    case "commit_before":
    case "commit_lost_ack":
      return once ? "pass" : "fail";
    case "kill_after_journal":
    case "kill_after_extract":
      return once && o.resumed >= 1 ? "pass" : "fail";
    case "concurrent_commit":
      return once && o.conflicts >= 1 ? "pass" : "fail";
    case "brief_lost_ack":
      // Three turn extractions, then one brief write and one speech call.
      return o.partial === "recovered" && o.brief?.first === "lost" && o.brief.retry === "unchanged" &&
        o.stubCalls === o.of + 2
        ? "pass"
        : "fail";
  }
}

const SEVERITY: PartialTurn[] = ["lost_completed", "duplicated", "dropped", "marked", "recovered"];
const worst = (outcomes: PartialTurn[]) =>
  SEVERITY.find((s) => outcomes.includes(s)) ?? "recovered";

export async function runFault(
  name: FaultName,
  seed: number,
  env: ScenarioEnv,
  overrides: { after?: number } = {},
): Promise<FaultResult> {
  const random = rng(seed * 7919 + FAULTS.indexOf(name));
  const jitter = () => Math.floor(random() * 25);
  const { plan, variant } = planFor(name, seed);
  if (plan && overrides.after) plan.after = overrides.after;
  const providerBefore = env.providerCalls();
  const turns = fixtures.turns;
  const turn2Before = env.extractCalls(turns.t2.text);

  const user = await env.newUser();
  try {
    let conflicts = 0;
    const routed = routerFetch(env);
    const observed = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const response = await routed(input, init);
      if (MATCH.commit(String(input))) {
        const body = await response.clone().json().catch(() => null);
        if (body?.status === "conflict") conflicts += 1;
      }
      return response;
    }) as typeof fetch;
    const fault = plan
      ? faultyFetch({ realFetch: observed, plan: { match: MATCH[plan.matcher], mode: plan.mode, after: plan.after } })
      : null;
    const fetchImpl = (fault?.fetchImpl ?? observed) as typeof fetch;
    const killing = plan?.mode === "kill" || plan?.mode === "kill_after";

    // One client per scenario, as the app has one: its fetch is the faulty one.
    useSupabase(
      createClient(env.supabaseUrl, env.anonKey, {
        global: { fetch: fetchImpl, headers: { Authorization: `Bearer ${user.token}` } },
        auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      }),
    );
    const client = (storage = deviceStorage()) =>
      createEvalClient({ token: user.token, notebookId: user.notebookId, storage, fetchImpl });
    const clients: EvalClient[] = [];
    const track = (c: EvalClient) => (clients.push(c), c);

    let completed: string[];
    let partial: string[];
    let resumed = 0;
    let brief: FaultResult["brief"];

    if (name === "concurrent_commit") {
      // Two devices open the notebook at the same revision and each commits a
      // turn naming the same new person; the later one must rebase.
      const phone = track(client());
      await phone.boot();
      await phone.speak(turns.t1.text);
      const laptopStorage = deviceStorage();
      const laptop = track(client(laptopStorage));
      await laptop.boot();
      await Promise.all([
        phone.speak(turns.t2.text),
        sleep(jitter()).then(() => laptop.speak(turns.t2b.text)),
      ]);
      const restarted = track(client(laptopStorage));
      resumed = (await restarted.boot()).resumed;
      await restarted.speak(turns.t3.text);
      completed = [turns.t1.text, turns.t3.text];
      partial = [turns.t2.text, turns.t2b.text];
    } else {
      const storage = deviceStorage();
      const first = track(client(storage));
      await first.boot();
      await first.speak(turns.t1.text);
      await sleep(jitter());
      await untilDoneOrKilled(first.speak(turns.t2.text), fault, killing);
      // Restart: a new process, same device storage, state from the database.
      const restarted = track(client(storage));
      resumed = (await restarted.boot()).resumed;
      await restarted.speak(turns.t3.text);
      if (name === "brief_lost_ack") {
        // Closing the session: the app retries a close whose answer was lost.
        const close = async () => {
          const response = await fetchImpl(`${GATEWAY}/v1/notebooks/${user.notebookId}/brief`, {
            method: "POST",
            headers: { authorization: `Bearer ${user.token}`, "content-type": "application/json" },
            body: "{}",
          });
          const body = (await response.json().catch(() => null)) as { status?: string; code?: string } | null;
          return body?.status ?? `http_${response.status}:${body?.code ?? ""}`;
        };
        brief = { first: "", retry: null };
        try {
          brief.first = await close();
        } catch {
          brief.first = "lost";
          brief.retry = await close();
        }
        completed = [turns.t1.text, turns.t2.text, turns.t3.text];
        partial = [];
      } else {
        completed = [turns.t1.text, turns.t3.text];
        partial = [turns.t2.text];
      }
    }

    const audit = await env.audit(user.userId);
    const landed = await env.texts(user.userId);
    const entriesFor = (text: string) => landed.journal.filter((t) => t === text).length;
    const kept = completed.filter((text) => entriesFor(text) >= 1).length;
    const classify = (text: string): PartialTurn => {
      const n = entriesFor(text);
      if (n > 1) return "duplicated";
      if (n === 1) return "recovered";
      return landed.turns.includes(text) ? "marked" : "dropped";
    };
    let partialTurn: PartialTurn;
    if (kept < completed.length) partialTurn = "lost_completed";
    else if (name === "brief_lost_ack") {
      const rows = audit.counts.session_briefs ?? 0;
      partialTurn = rows === 1 ? "recovered" : rows === 0 ? "dropped" : "duplicated";
    } else partialTurn = worst(partial.map(classify));
    // A completed turn written twice is a duplicate, whatever the partial did.
    if (completed.some((text) => entriesFor(text) > 1) && partialTurn !== "lost_completed") partialTurn = "duplicated";

    const triggered = name === "concurrent_commit" ? conflicts > 0 : Boolean(fault?.triggered());
    const duplicateTotal = Object.values(audit.duplicates).reduce((a, b) => a + b, 0);
    const providerAfter = env.providerCalls();
    const turn2Extractions = env.extractCalls(turns.t2.text) - turn2Before;
    const outcome = judge(name, {
      triggered,
      kept,
      of: completed.length,
      partial: partialTurn,
      duplicateTotal,
      resumed,
      turn2Extractions,
      conflicts,
      brief,
      stubCalls: providerAfter.stub - providerBefore.stub,
    });

    return {
      fault: name,
      seed,
      variant,
      triggered,
      outcome,
      pass: outcome === "pass",
      completed_turns_kept: { n: kept, of: completed.length },
      partial_turn: partialTurn,
      duplicates: audit.duplicates,
      counts: audit.counts,
      resumed,
      turn2_extractions: turn2Extractions,
      conflicts,
      ...(brief ? { brief } : {}),
      client_errors: clients.reduce((n, c) => n + c.errors.length, 0),
      provider_real_calls: providerAfter.real - providerBefore.real,
      provider_stub_calls: providerAfter.stub - providerBefore.stub,
    };
  } finally {
    await env.cleanupUser(user.userId);
  }
}

