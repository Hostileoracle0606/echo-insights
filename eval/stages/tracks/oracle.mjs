// Oracle retrieval: the world's correct end-state graph is written straight
// into a notebook (no extraction, no admission), the 50 background
// distractors are added, and production retrieve-memory ranks entities.
// hybrid = after embed-entities embeds every entity (production);
// lexical = the same notebook with no embedding rows, which is retrieve-memory's
// own fallback when it has no semantic seeds.
import { backgroundRows } from '../../memory/background.mjs';
import { embedNotebook } from '../../memory/probe.mjs';
import { restoreSnapshot } from '../../memory/snapshot.mjs';
import { withUser } from '../../memory/stack.mjs';
import { mrr, ndcgAt, recallAt } from '../metrics.mjs';

const BASE = Date.parse('2026-10-01T09:00:00Z');
const at = (session) => new Date(BASE + session * 86_400_000).toISOString();
const an = (w) => (/^[aeiou]/i.test(w) ? `an ${w}` : `a ${w}`);
const LABEL_TEXT = {
  lives_in: 'lives in', works_at: 'works at', located_in: 'is based in', helps_with: 'helps with',
  grew_up_in: 'grew up in', went_to: 'went to',
};

/**
 * One fixed template, from world facts only: the entity's attributes, then each
 * active relation it takes part in. Superseded facts stay as relation rows
 * (with superseded_at), not in the description.
 */
function description(entity, world, names) {
  const parts = [];
  if (entity.type === 'person') {
    const { bond, role } = entity.attributes ?? {};
    parts.push(`${entity.name} is the user's ${bond ?? 'acquaintance'}${role ? `, who works as ${an(role)}` : ''}.`);
  } else {
    parts.push(`${entity.name} is ${an(entity.type === 'organization' ? 'organisation' : entity.type)} the user mentioned.`);
  }
  for (const r of world.finalGraph.relations) {
    if (r.supersededInSession != null || (r.source !== entity.id && r.target !== entity.id)) continue;
    parts.push(`${names.get(r.source)} ${LABEL_TEXT[r.label] ?? r.label.replace(/_/g, ' ')} ${names.get(r.target)}.`);
  }
  return parts.join(' ');
}

/** The world's final graph as a snapshot restoreSnapshot can write. */
export function goldSnapshot(world) {
  const names = new Map(world.finalGraph.entities.map((e) => [e.id, e.name]));
  const firstSession = (id) => Math.min(...world.sessions.flatMap((s) => s.facts).filter((f) => f.subject === id || f.object === id).map((f) => f.session), world.sessions.length);
  return {
    version: 1,
    notebook: { title: `stages oracle: ${world.id}`, title_source: 'auto', started_at: at(1), revision: 1, conversation_mode: 'just_talk', mode_context: {} },
    suppressionKey: null,
    tables: {
      journal_entries: [],
      conversation_turns: [],
      entity_suppressions: [],
      entities: [...world.finalGraph.entities].sort((a, b) => (a.id < b.id ? -1 : 1)).map((e) => ({
        id: e.id, name: e.name, type: e.type, description: description(e, world, names), metadata: {}, mentions: 1,
        first_seen: at(firstSession(e.id)), last_seen: at(world.sessions.length), questions: [], description_source: 'extracted',
      })),
      relations: world.finalGraph.relations.map((r) => ({
        id: `${r.source}__${r.label}__${r.target}`, source_id: r.source, target_id: r.target, label: r.label, metadata: {},
        created_at: at(1), superseded_at: r.supersededInSession != null ? at(r.supersededInSession) : null,
      })).sort((a, b) => (a.id < b.id ? -1 : 1)),
    },
  };
}

/** Every world entity embedded, all with one model; background rows may also be present. */
export function assertEmbedded(rows, entityIds) {
  const have = new Set(rows.map((r) => r.entity_id));
  const missing = entityIds.filter((id) => !have.has(id));
  if (missing.length) throw new Error(`oracle hybrid: embeddings missing for ${missing.join(', ')}`);
  const models = new Set(rows.map((r) => r.embedding_model));
  if (models.size !== 1) throw new Error(`oracle hybrid: mixed embedding models ${[...models].join(', ')}`);
}

/** Rank metrics for one answerable query; null for unanswerable ones. */
export function scoreQuery(ranked, query) {
  if (!query.answerable || !query.gold.length) return null;
  const answers = query.gold.filter((g) => g.relevance === 2).map((g) => g.entityId);
  return {
    recallAt1: recallAt(ranked, answers, 1),
    recallAt5: recallAt(ranked, answers, 5),
    recallAt10: recallAt(ranked, answers, 10),
    mrr: mrr(ranked, answers),
    ndcg10: ndcgAt(ranked, query.gold, 10),
  };
}

export async function retrieveRanked({ stack, user, notebookId, query, k = 10 }) {
  const headers = { apikey: stack.anonKey, authorization: `Bearer ${user.token}`, 'content-type': 'application/json' };
  const snap = await (await fetch(`${stack.url}/rest/v1/rpc/get_notebook_snapshot`, {
    method: 'POST', headers, body: JSON.stringify({ p_notebook_id: notebookId }),
  })).json();
  const state = snap.state;
  const started = Date.now();
  const response = await fetch(`${stack.url}/functions/v1/retrieve-memory`, {
    method: 'POST', headers, signal: AbortSignal.timeout(60_000),
    body: JSON.stringify({ scope: 'notebook', notebookId, query, limit: k, state: { entities: state.entities, relations: state.relations, entries: state.entries } }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`retrieve-memory → ${response.status} ${body.error ?? ''}`);
  return { ranked: (body.entityIds ?? []).slice(0, k), context: body.context ?? '', latencyMs: Date.now() - started };
}

/** Restores `snapshot` (gold or extracted) with the background, embeds per mode, and ranks each query. */
export async function rankWorld({ world, written, snapshot, stack, embedSecret, mode, k = 10 }) {
  const texts = new Map(written.queries.map((q) => [q.id, q.text]));
  return withUser(stack, async (user) => {
    const { notebookId } = await restoreSnapshot({ ...stack.admin, userId: user.id, snapshot });
    const rows = backgroundRows({ userId: user.id, notebookId });
    await stack.call('/rest/v1/entities', { method: 'POST', body: rows.entities });
    await stack.call('/rest/v1/relations', { method: 'POST', body: rows.relations });
    if (mode === 'hybrid') {
      await embedNotebook({ url: stack.url, secret: embedSecret, notebookId });
      const embedded = await stack.call(`/rest/v1/entity_embeddings?notebook_id=eq.${notebookId}&select=entity_id,embedding_model`);
      assertEmbedded(embedded, snapshot.tables.entities.map((e) => e.id));
    }
    const out = [];
    for (const q of world.queries) {
      if (!texts.has(q.id)) continue;
      const r = await retrieveRanked({ stack, user, notebookId, query: texts.get(q.id), k });
      out.push({ worldId: world.id, queryId: q.id, family: q.family, mode, answerable: q.answerable, ...r, metrics: scoreQuery(r.ranked, q) });
    }
    return out;
  });
}
