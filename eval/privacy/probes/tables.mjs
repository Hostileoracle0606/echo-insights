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

export function classifySelect({ kind, table, status, body, markers, seeded }) {
  if (status >= 400) return 'deny';
  const rows = rowsOf(body);
  if (!rows) return 'error';
  const marked = markers.some((m) => body.includes(m));
  if (!OWNER_READABLE.has(table)) return rows.length ? 'leak' : 'deny';
  if (kind === 'owner') return !seeded || marked ? 'allow' : 'deny';
  return marked ? 'leak' : 'deny';
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

function writeRequest(operation, table, owner) {
  const { column, value } = ownerFilter(table, owner);
  const query = ownerQuery(table, owner);
  const body = value ? JSON.stringify({ [column]: value }) : JSON.stringify({});
  if (operation === 'insert') return { method: 'POST', query: '', body };
  if (operation === 'update') return { method: 'PATCH', query, body };
  return { method: 'DELETE', query, body: undefined };
}

export async function probeTables({
  url, tables = USER_TABLES, kinds, headersByKind, owner, markers, seededTables,
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

  for (const table of tables) {
    for (const kind of kinds) {
      const headers = headersByKind[kind];
      const read = await call(table, undefined, headers);
      const observed = read.status === 0 ? 'error' : classifySelect({
        kind, table, status: read.status, body: read.body, markers, seeded: seededTables.has(table),
      });
      cells.push(cell({ surface: 'table', target: table, credential: kind, operation: 'select', expected: expectedFor(kind, 'select', table), observed }));
      if (kind === 'owner') continue;

      for (const operation of WRITES) {
        const before = await snapshot(table);
        const response = await call(table, writeRequest(operation, table, owner), headers);
        const after = await snapshot(table);
        const rows = response.status < 300 ? rowsOf(response.body) : null;
        const wrote = before !== after || (rows !== null && rows.length > 0);
        cells.push(cell({
          surface: 'table', target: table, credential: kind, operation,
          expected: 'deny', observed: wrote ? 'leak' : 'deny',
        }));
      }
    }
  }
  return cells;
}
