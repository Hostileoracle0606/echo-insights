// Probe phase for one scenario: restore its snapshot into a fresh user, embed
// the entities, ask retrieve-memory every probe, and read the session brief.
// Retrieval is local (gte-small) and free; the brief's text call is Gemini and
// is budgeted by the caller, its TTS call answered by a stub (audio is not
// scored, and TTS quota is separate).
import { createSupabaseAuthorizer } from '../../infra/lambda/supabase-authorizer/core.mjs';
import { createSessionBriefHandler } from '../../infra/lambda/close-session/brief.mjs';
import { gatewayInvoke } from '../privacy/probes/lambdas.mjs';
import { restoreSnapshot } from './snapshot.mjs';

export const RETRIEVE_K = 8;

// retrieve-memory returns one ranked list of entity ids and a context string;
// it does not say which path (lexical, semantic, graph expansion) found each
// item, so every item is reported as `combined` rather than guessed.
export function retrievedItems(state, entityIds) {
  const entities = state.entities ?? {};
  const active = Object.values(state.relations ?? {}).filter((r) => !r.supersededAt);
  const nameOf = (id) => entities[id]?.name ?? id;
  return entityIds.filter((id) => entities[id]).map((id) => {
    const lines = active.filter((r) => r.source === id || r.target === id)
      .map((r) => `${nameOf(r.source)} ${r.label} ${nameOf(r.target)}`);
    const text = [entities[id].description ?? '', ...lines].filter(Boolean).join('\n');
    return { name: entities[id].name, text, path: 'combined' };
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

export async function probeScenario({ snapshot, scenario, stack, embedSecret, brief }) {
  const users = [];
  try {
    const user = await stack.createUser(users);
    const { notebookId } = await restoreSnapshot({ ...stack.admin, userId: user.id, snapshot });
    const embed = await fetch(`${stack.url}/functions/v1/embed-entities`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-internal-secret': embedSecret },
      body: JSON.stringify({ notebookId }),
      signal: AbortSignal.timeout(120_000),
    });
    const embedded = await embed.json().catch(() => ({}));
    if (!embed.ok || embedded.ok === false) throw new Error(`embed-entities → ${embed.status} ${embedded.stage ?? ''}`);

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
  } finally {
    for (const id of users) await stack.deleteUser(id);
  }
}
