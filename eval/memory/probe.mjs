// Probe phase for one scenario: restore its snapshot into a fresh user, embed
// the entities, ask retrieve-memory every probe, and read the session brief.
// Retrieval is local (gte-small) and free; the brief's text call is Gemini and
// is budgeted by the caller, its TTS call answered by a stub (audio is not
// scored, and TTS quota is separate).
import { createSupabaseAuthorizer } from '../../infra/lambda/supabase-authorizer/core.mjs';
import { createSessionBriefHandler } from '../../infra/lambda/close-session/brief.mjs';
import { gatewayInvoke } from '../privacy/probes/lambdas.mjs';
import { restoreSnapshot } from './snapshot.mjs';
import { withUser } from './stack.mjs';

export const RETRIEVE_K = 8;

// retrieve-memory returns one ranked list of entity ids and a context string;
// it does not say which path (lexical, semantic, graph expansion) found each
// item, so every item is reported as `combined` rather than guessed.
export function retrievedItems(state, entityIds) {
  const entities = state.entities ?? {};
  const relations = Object.values(state.relations ?? {});
  const nameOf = (id) => entities[id]?.name ?? id;
  const linesFor = (id, superseded) => relations
    .filter((r) => Boolean(r.supersededAt) === superseded && (r.source === id || r.target === id))
    .map((r) => `${nameOf(r.source)} ${r.label} ${nameOf(r.target)}`);
  return entityIds.filter((id) => entities[id]).map((id) => {
    const text = [entities[id].description ?? '', ...linesFor(id, false)].filter(Boolean).join('\n');
    // Superseded relations: what the graph remembers as earlier, kept apart
    // from current text (scored only for sequence preservation).
    const history = linesFor(id, true).join('\n');
    return { name: entities[id].name, text, history, path: 'combined' };
  });
}

export function briefText(brief) {
  if (!brief) return null;
  const out = [];
  const walk = (v) => {
    if (typeof v === 'string') out.push(v);
    else if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === 'object') Object.values(v).forEach(walk);
  };
  walk(brief);
  return out.join('\n');
}

// One second of silence: the brief handler saves whatever audio it gets.
function ttsStub() {
  return new Response(JSON.stringify({
    candidates: [{ content: { parts: [{ inlineData: { mimeType: 'audio/L16;rate=24000', data: 'AAAAAA==' } }] } }],
  }), { status: 200, headers: { 'content-type': 'application/json' } });
}

/** Writes the session brief the app would get at close, through the real handler. */
export async function runBrief({ stack, user, notebookId, geminiKey, fetchImpl }) {
  const briefFetch = async (url, init) => (String(url).includes('-tts:') ? ttsStub() : fetchImpl(url, init));
  const deps = { supabaseUrl: stack.url, publishableKey: stack.anonKey, fetchImpl: briefFetch,
    getPermanentCredential: async () => geminiKey };
  await fetchImpl.pace?.();
  const response = await gatewayInvoke({
    authorize: createSupabaseAuthorizer(deps),
    handler: createSessionBriefHandler({ ...deps, sleep: async () => {}, log: () => {} }),
    event: { headers: { authorization: `Bearer ${user.token}` }, pathParameters: { notebookId }, requestContext: {}, body: '{}' },
  });
  const stop = fetchImpl.stopReason?.();
  if (stop) throw stop;
  const status = JSON.parse(response.body || '{}');
  if (response.statusCode !== 200 || status.status !== 'ready') {
    return { brief: null, outcome: `${response.statusCode} ${status.status ?? status.code ?? ''}`.trim() };
  }
  const rows = await stack.call(`/rest/v1/session_briefs?select=brief&user_id=eq.${user.id}`);
  return { brief: rows[0]?.brief ?? null, outcome: 'ready' };
}

// Idempotent (it re-embeds the notebook and prunes orphans), so a 5xx is
// retried: a freshly started edge runtime cancels the first gte-small load at
// its CPU-time limit. ok:false is a real failure and is not retried.
export async function embedNotebook({ url, secret, notebookId, fetchImpl = fetch,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) }) {
  for (let attempt = 1; ; attempt += 1) {
    const response = await fetchImpl(`${url}/functions/v1/embed-entities`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-internal-secret': secret },
      body: JSON.stringify({ notebookId }),
      signal: AbortSignal.timeout(120_000),
    });
    const body = await response.json().catch(() => ({}));
    if (response.ok && body.ok !== false) return body;
    if (response.status < 500 || attempt >= 3) {
      throw new Error(`embed-entities → ${response.status} ${body.stage ?? ''}`.trim());
    }
    await sleep(2000 * attempt);
  }
}

/** Returns {results, leftover}: leftover lists a test user whose delete failed after retries. */
export async function probeScenario({ snapshot, scenario, stack, embedSecret, brief }) {
  const { value: results, leftover } = await withUser(stack, async (user) => {
    const { notebookId } = await restoreSnapshot({ ...stack.admin, userId: user.id, snapshot });
    await embedNotebook({ url: stack.url, secret: embedSecret, notebookId });

    const userHeaders = { apikey: stack.anonKey, authorization: `Bearer ${user.token}`, 'content-type': 'application/json' };
    const snap = await (await fetch(`${stack.url}/rest/v1/rpc/get_notebook_snapshot`, {
      method: 'POST', headers: userHeaders, body: JSON.stringify({ p_notebook_id: notebookId }),
    })).json();
    const state = snap.state;
    const extracted = Object.values(state.entities ?? {}).map((e) => e.name);

    const briefResult = typeof brief === 'function' ? await brief({ user, notebookId }) : brief ?? null;
    const results = [];
    for (const [probeIndex, probe] of scenario.probes.entries()) {
      const response = await fetch(`${stack.url}/functions/v1/retrieve-memory`, {
        method: 'POST',
        headers: userHeaders,
        body: JSON.stringify({
          scope: 'notebook', notebookId, query: probe.ask, limit: RETRIEVE_K,
          state: { entities: state.entities, relations: state.relations, entries: state.entries },
        }),
        signal: AbortSignal.timeout(60_000),
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(`retrieve-memory → ${response.status} ${body.error ?? ''}`);
      results.push({
        scenario: scenario.id,
        probeIndex,
        retrieved: retrievedItems(state, (body.entityIds ?? []).slice(0, RETRIEVE_K)),
        context: body.context ?? '',
        brief: briefResult?.brief ? { text: briefText(briefResult.brief) } : null,
        briefOutcome: briefResult?.outcome ?? 'not_run',
        extracted,
      });
    }
    return results;
  });
  return { results, leftover };
}
