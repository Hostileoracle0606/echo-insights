// Row-level security probes over every user table, through PostgREST with raw
// status codes (client SDKs mask them).
import { cell } from '../report.mjs';

export const USER_TABLES = Object.freeze([
  'profiles', 'notebooks', 'journal_entries', 'entities', 'relations', 'follow_ups',
  'asked_questions', 'conversation_turns', 'conversation_runtime_sessions',
  'conversation_runtime_inbox', 'notebook_commit_requests', 'entity_embeddings',
  'retrieve_rate_limits', 'entity_suppressions', 'forget_erase_jobs', 'session_briefs',
  'session_cards', 'suppression_keys',
]);

// Tables with an owner SELECT policy on main. Every other table is server-only.
export const OWNER_READABLE = new Set([
  'asked_questions', 'conversation_turns', 'entities', 'entity_suppressions', 'follow_ups',
  'journal_entries', 'notebooks', 'profiles', 'relations', 'session_briefs', 'session_cards',
]);

const WRITES = ['insert', 'update', 'delete'];

export function expectedFor(kind, operation, table) {
  return kind === 'owner' && operation === 'select' && OWNER_READABLE.has(table) ? 'allow' : 'deny';
}

function rowsOf(body) {
  try {
    const parsed = JSON.parse(body);
    return Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

const codeOf = (body) => {
  try { return JSON.parse(body)?.code ?? null; } catch { return null; }
};

// Only an auth refusal proves a deny; a missing table or bad request proves nothing.
const refused = (status, body) => status === 401 || status === 403 || codeOf(body) === '42501';

export function classifySelect({ kind, table, status, body, markers }) {
  if (refused(status, body)) return 'deny';
  if (status === 0 || status >= 300) return 'error';
  const rows = rowsOf(body);
  if (!rows) return 'error';
  const marked = markers.some((m) => body.includes(m));
  if (!OWNER_READABLE.has(table)) return rows.length ? 'leak' : 'deny';
  if (kind === 'owner') return marked ? 'allow' : 'deny';
  return marked ? 'leak' : 'deny';
}

// Postgres checks RLS WITH CHECK before constraints, so an integrity error
// means the policy already accepted the row.
const AFTER_RLS = new Set(['23502', '23503', '23505', '23514', '22P02']);

export function classifyWrite({ status, body, changed }) {
  if (changed) return 'leak';
  if (refused(status, body)) return 'deny';
  if (AFTER_RLS.has(codeOf(body))) return 'allow';
  if (status >= 200 && status < 300) {
    const rows = rowsOf(body);
    if (rows === null) return 'error';
    return rows.length ? 'leak' : 'deny';
  }
  return 'error';
}

// A filter that targets the owner's rows, or every row where no owner column exists.
function ownerFilter(table, owner) {
  if (table === 'notebook_commit_requests') return { column: 'notebook_id', value: owner.notebookId };
  if (table === 'conversation_runtime_inbox') return { column: 'session_id' };
  if (table === 'retrieve_rate_limits') return { column: 'scope' };
  return { column: 'user_id', value: owner.userId };
}

// PostgREST filter selecting the owner's rows (all rows for owner-less tables).
export function ownerQuery(table, owner) {
  const { column, value } = ownerFilter(table, owner);
  return value ? `${column}=eq.${value}` : `${column}=not.is.null`;
}

// Updates try to take the row: hand it to the attacker, or overwrite its payload.
function takeover(table, attackerId) {
  if (table === 'notebook_commit_requests') return { result: { taken: true } };
  if (table === 'conversation_runtime_inbox') return { observation: { taken: true } };
  if (table === 'retrieve_rate_limits') return { count: 999_999 };
  return { user_id: attackerId };
}

export async function probeTables({
  url, tables = USER_TABLES, kinds, headersByKind, owner, attackerId, markers, rowFor,
  fetchImpl = fetch, snapshot,
}) {
  const cells = [];
  const call = async (table, { method = 'GET', query = 'select=*', body } = {}, headers) => {
    try {
      const response = await fetchImpl(`${url}/rest/v1/${table}?${query}`, {
        method,
        headers: { ...headers, 'content-type': 'application/json', prefer: 'return=representation' },
        body,
        signal: AbortSignal.timeout(10_000),
      });
      return { status: response.status, body: await response.text() };
    } catch {
      return { status: 0, body: '' };
    }
  };
  const push = (fields) => cells.push(cell({ surface: 'table', ...fields }));

  for (const table of tables) {
    // Without A's rows in the table, no cell here can observe anything.
    const present = (await snapshot(table)) !== '[]';
    let unique = 0;
    for (const kind of kinds) {
      const headers = headersByKind[kind];
      const expected = expectedFor(kind, 'select', table);
      const read = await call(table, undefined, headers);
      push({
        target: table, credential: kind, operation: 'select', expected,
        control: kind === 'owner' && expected === 'allow',
        observed: present ? classifySelect({ kind, table, status: read.status, body: read.body, markers }) : 'error',
      });
      if (kind === 'owner') continue;

      const requests = {
        insert: { method: 'POST', query: '', body: JSON.stringify(rowFor(table, `probe-${kind}-${unique++}`)) },
        update: { method: 'PATCH', query: ownerQuery(table, owner), body: JSON.stringify(takeover(table, attackerId)) },
        delete: { method: 'DELETE', query: ownerQuery(table, owner) },
      };
      for (const operation of WRITES) {
        const before = await snapshot(table);
        const response = await call(table, requests[operation], headers);
        const after = await snapshot(table);
        push({
          target: table, credential: kind, operation, expected: 'deny',
          observed: present ? classifyWrite({ ...response, changed: before !== after }) : 'error',
        });
      }
    }
  }
  return cells;
}
