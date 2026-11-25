// One valid row per user table, owned by user A. Used to seed A's data (so
// every table has something to leak) and as the body of insert probes (so a
// refused insert is refused by RLS, not by a missing column).

// Parents before children; profiles is created by the signup trigger.
export const SEED_ORDER = Object.freeze([
  'notebooks', 'entities', 'relations', 'journal_entries', 'conversation_turns', 'follow_ups',
  'asked_questions', 'session_cards', 'session_briefs', 'entity_suppressions', 'suppression_keys',
  'forget_erase_jobs', 'conversation_runtime_sessions', 'conversation_runtime_inbox',
  'notebook_commit_requests', 'entity_embeddings', 'retrieve_rate_limits',
  'memory_facts', 'memory_fact_corrections', 'conversation_state', 'memory_backfill_progress',
  'account_deletion_requests',
]);

const uuidFrom = (seed) => {
  const hex = Buffer.from(seed).toString('hex').padEnd(32, '0').slice(0, 32);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
};

export function rowFor(table, { userId, notebookId, sessionId, marker, unique }) {
  const now = new Date().toISOString();
  const owned = { user_id: userId, notebook_id: notebookId };
  const rows = {
    profiles: { user_id: userId, display_name: marker },
    notebooks: { user_id: userId, title: marker, started_at: now },
    entities: { ...owned, id: `pm-entity-${unique}`, name: marker, type: 'project', first_seen: now, last_seen: now },
    relations: { ...owned, id: `pm-relation-${unique}`, source_id: 'pm-entity-a', target_id: 'pm-entity-b', label: marker },
    journal_entries: { ...owned, text: marker, created_at: now },
    conversation_turns: { ...owned, turn_id: `pm-turn-${unique}`, speaker: 'user', text: marker, spoken_at: now },
    follow_ups: { ...owned, question: marker },
    asked_questions: { ...owned, question: marker },
    session_cards: { ...owned, conversation_mode: 'just_talk', source_revision: 1, card: { note: marker } },
    session_briefs: { user_id: userId, source_revision: 1, brief: { note: marker }, audio: '\\x00', sample_rate: 24000 },
    entity_suppressions: { user_id: userId, entity_hash: `${marker}-${unique}`, kind: 'removed' },
    suppression_keys: { user_id: userId, key: `\\x${Buffer.from(unique).toString('hex')}` },
    forget_erase_jobs: { user_id: userId, entity_hash: marker, hashes: [marker], max_words: 1 },
    conversation_runtime_sessions: { ...owned, id: uuidFrom(`session-${unique}`), device_id: uuidFrom(`device-${unique}`), mode: 'wiki' },
    conversation_runtime_inbox: { session_id: sessionId, sequence: 1 + (parseInt(Buffer.from(unique).toString('hex').slice(0, 6), 16) % 1_000_000), event_id: uuidFrom(`event-${unique}`), observation: { note: marker } },
    notebook_commit_requests: { notebook_id: notebookId, request_id: uuidFrom(`request-${unique}`), request_hash: marker, result: { note: marker } },
    entity_embeddings: { ...owned, entity_id: unique === 'seed' ? 'pm-entity-a' : 'pm-entity-b', embedding: JSON.stringify([1, ...Array(383).fill(0)]), embedding_model: 'gte-small@1', content_hash: marker },
    retrieve_rate_limits: { scope: `${marker}-${unique}`, window_start: now },
    memory_facts: { id: uuidFrom(`fact-${unique}`), user_id: userId, entity_id: 'pm-entity-a', attribute: 'city', status: 'confirmed', stated_at: now, value_text: marker, source_notebook_id: notebookId },
    memory_fact_corrections: { user_id: userId, fact_id: uuidFrom('fact-seed'), change: { note: marker }, read_back: marker },
    conversation_state: { notebook_id: notebookId, user_id: userId, state: { note: marker } },
    memory_backfill_progress: { user_id: userId, last_created_at: now, last_entry_id: uuidFrom(`entry-${unique}`) },
    account_deletion_requests: { user_id: userId, request_id: uuidFrom(`deletion-${unique}`) },
  };
  if (!(table in rows)) throw new Error(`no fixture row for ${table}`);
  return rows[table];
}
