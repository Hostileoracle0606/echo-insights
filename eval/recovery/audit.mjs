// Duplicate audit over one test user's memory rows, read with the service
// role so RLS can't hide a row. A duplicate is any row beyond the first with
// the same logical key:
//   journal_entries    (notebook, text) — the table has no turn id; every eval
//                      turn's text is unique, so text stands in for it
//   entities           (notebook, lower(name))
//   relations          (notebook, source, target, label), live rows only
//   conversation_turns (notebook, turn id)
//   session_briefs     (source notebook)

export function countDuplicates(rows, keyFn) {
  return rows.length - new Set(rows.map(keyFn)).size;
}

const SPECS = {
  journal_entries: { select: 'notebook_id,text', key: (r) => `${r.notebook_id}|${r.text}` },
  entities: { select: 'notebook_id,name', key: (r) => `${r.notebook_id}|${r.name.toLowerCase()}` },
  relations: {
    select: 'notebook_id,source_id,target_id,label', filter: '&superseded_at=is.null',
    key: (r) => `${r.notebook_id}|${r.source_id}|${r.target_id}|${r.label}`,
  },
  conversation_turns: { select: 'notebook_id,turn_id', key: (r) => `${r.notebook_id}|${r.turn_id}` },
  session_briefs: { select: 'source_notebook_id', key: (r) => `${r.source_notebook_id}` },
};

export const AUDITED_TABLES = Object.freeze(Object.keys(SPECS));

export async function auditUser({ url, adminHeaders, userId, fetchImpl = fetch }) {
  const counts = {};
  const duplicates = {};
  for (const [table, spec] of Object.entries(SPECS)) {
    const path = `/rest/v1/${table}?select=${spec.select}&user_id=eq.${userId}${spec.filter ?? ''}`;
    const response = await fetchImpl(`${url}${path}`, { headers: adminHeaders, signal: AbortSignal.timeout(15_000) });
    if (!response.ok) throw new Error(`audit ${table} → ${response.status}`);
    const rows = await response.json();
    counts[table] = rows.length;
    duplicates[table] = countDuplicates(rows, spec.key);
  }
  return { counts, duplicates };
}
