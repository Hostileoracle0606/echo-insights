// A scenario's committed graph, saved so probes can be rerun without spending
// extraction quota. Ids that belong to the throwaway user are replaced by
// placeholders, so the same graph has the same digest whoever owned it.
// Entity and relation ids are content slugs and turn ids are scripted, so
// they are kept as they are.
import { createHash } from 'node:crypto';

export const SNAPSHOT_TABLES = Object.freeze(
  ['notebooks', 'journal_entries', 'entities', 'relations', 'entity_suppressions', 'conversation_turns']);

const NOTEBOOK_FIELDS = ['title', 'title_source', 'started_at', 'ended_at', 'duration_seconds', 'entity_count',
  'summary', 'archived_at', 'revision', 'conversation_mode', 'mode_context', 'transcript_forgotten_at'];
// context_text is written by a trigger from text; user_id/notebook_id are the owner's.
const DROPPED = new Set(['user_id', 'notebook_id', 'context_text']);
const ORDER = {
  journal_entries: (r) => `${r.created_at}\u0000${r.text}`,
  entities: (r) => r.id,
  relations: (r) => r.id,
  entity_suppressions: (r) => r.entity_hash,
  conversation_turns: (r) => `${r.spoken_at}\u0000${r.turn_id}`,
};
const CHILD_TABLES = SNAPSHOT_TABLES.filter((t) => t !== 'notebooks');

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value ?? null);
}

function rewrite(value, ids) {
  if (typeof value === 'string') {
    let out = value;
    for (const [id, placeholder] of ids) out = out.split(id).join(placeholder);
    return out;
  }
  if (Array.isArray(value)) return value.map((v) => rewrite(v, ids));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, rewrite(v, ids)]));
  }
  return value;
}

/** Pure: rows as PostgREST returns them → a snapshot with no owner ids. */
export function toSnapshot({ userId, notebook, rows, suppressionKey = null }) {
  const sorted = Object.fromEntries(CHILD_TABLES.map((t) => [t, [...(rows[t] ?? [])]
    .sort((a, b) => (ORDER[t](a) < ORDER[t](b) ? -1 : ORDER[t](a) > ORDER[t](b) ? 1 : 0))]));
  const ids = new Map([[userId, '$user'], [notebook.id, '$notebook']]);
  sorted.journal_entries.forEach((e, i) => ids.set(e.id, `$entry-${i + 1}`));
  const tables = Object.fromEntries(CHILD_TABLES.map((t) => [t, sorted[t].map((row) =>
    Object.fromEntries(Object.entries(row).filter(([k]) => !DROPPED.has(k))))]));
  return rewrite({
    version: 1,
    notebook: Object.fromEntries(NOTEBOOK_FIELDS.filter((k) => notebook[k] !== undefined).map((k) => [k, notebook[k]])),
    suppressionKey,
    tables,
  }, ids);
}

export function snapshotDigest(snapshot) {
  const { version, notebook, suppressionKey, tables } = snapshot;
  return createHash('sha256').update(canonicalJson({ version, notebook, suppressionKey, tables })).digest('hex');
}

async function rest(url, adminHeaders, path, { method = 'GET', body, prefer } = {}) {
  const response = await fetch(`${url}/rest/v1/${path}`, {
    method,
    headers: { ...adminHeaders, ...(prefer ? { prefer } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} ${path.split('?')[0]} → ${response.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

export async function takeSnapshot({ url, adminHeaders, userId, notebookId }) {
  const notebooks = await rest(url, adminHeaders,
    `notebooks?select=*&user_id=eq.${userId}${notebookId ? `&id=eq.${notebookId}` : ''}`);
  if (notebooks.length !== 1) throw new Error(`expected one notebook, found ${notebooks.length}`);
  const [notebook] = notebooks;
  const rows = {};
  for (const table of CHILD_TABLES) {
    const scope = table === 'entity_suppressions' ? `user_id=eq.${userId}` : `notebook_id=eq.${notebook.id}`;
    rows[table] = await rest(url, adminHeaders, `${table}?select=*&${scope}`);
  }
  const keys = await rest(url, adminHeaders, `suppression_keys?select=key&user_id=eq.${userId}`);
  return toSnapshot({ userId, notebook, rows, suppressionKey: keys[0]?.key ?? null });
}

export async function restoreSnapshot({ url, adminHeaders, userId, snapshot }) {
  const [notebook] = await rest(url, adminHeaders, 'notebooks', {
    method: 'POST', prefer: 'return=representation', body: { ...snapshot.notebook, user_id: userId },
  });
  const ids = new Map([['$user', userId], ['$notebook', notebook.id]]);
  if (snapshot.suppressionKey) {
    await rest(url, adminHeaders, 'suppression_keys?on_conflict=user_id', {
      method: 'POST', prefer: 'resolution=merge-duplicates', body: { user_id: userId, key: snapshot.suppressionKey },
    });
  }
  // Parents before children: entities before the relations that point at them.
  for (const table of ['entities', 'relations', 'journal_entries', 'conversation_turns', 'entity_suppressions']) {
    const rows = snapshot.tables[table].map((row) => {
      const { id, ...rest } = row;
      const owned = table === 'entity_suppressions' ? { user_id: userId } : { user_id: userId, notebook_id: notebook.id };
      return { ...(table === 'journal_entries' ? rest : row), ...owned };
    });
    if (rows.length) await rest(url, adminHeaders, table, { method: 'POST', body: rewrite(rows, ids) });
  }
  return { notebookId: notebook.id };
}
