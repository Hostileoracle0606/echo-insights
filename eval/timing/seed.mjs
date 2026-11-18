// Seeded history for the timing eval, on local Supabase only.
//
//   source eval/privacy/local-env.sh
//   TIMING_USER_PASSWORD=… node eval/timing/seed.mjs --entities 0|50|500 [--email timing-eval-…@example.test]
//   node eval/timing/seed.mjs --cleanup
//
// Without --email it creates a new timing-eval user; with it, that user's
// history is replaced (so a simulator signed in once can be re-sized). Prints
// only the email. Every name is synthetic vocabulary, never real content.
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

export const ENTITIES_PER_NOTEBOOK = 10;
const EMAIL = /^timing-eval-[0-9a-f]+@example\.test$/;
export const isTimingEmail = (email) => EMAIL.test(email ?? '');

const ADJ = ['amber', 'brisk', 'cedar', 'dusky', 'early', 'fallow', 'gilded', 'hazel', 'ivory', 'jade',
  'keen', 'lunar', 'misty', 'north', 'olive', 'pale', 'quiet', 'russet', 'slate', 'tidal', 'umber',
  'vivid', 'woolly', 'young', 'zesty'];
const NOUN = ['harbor', 'meadow', 'lantern', 'orchard', 'ridge', 'kettle', 'garden', 'bridge', 'canyon',
  'market', 'studio', 'library', 'harvest', 'compass', 'quarry', 'pillar', 'thicket', 'valley',
  'workshop', 'beacon', 'cottage', 'delta', 'estuary', 'forge', 'grove'];
const TYPES = ['person', 'place', 'organization', 'project', 'event', 'activity', 'concept'];

export const vocabularyName = (i) => `${ADJ[i % ADJ.length]} ${NOUN[Math.floor(i / ADJ.length) % NOUN.length]}`;

/** A deterministic 384-dim unit vector (synthetic: cost-realistic, meaning-free). */
function unitVector(seed) {
  const v = [];
  let block = 0;
  while (v.length < 384) {
    const bytes = createHash('sha256').update(`${seed}:${block++}`).digest();
    for (let i = 0; i < bytes.length && v.length < 384; i += 2) v.push(bytes.readUInt16BE(i) / 65535 - 0.5);
  }
  const norm = Math.hypot(...v);
  return v.map((x) => x / norm);
}

export function buildHistory({ userId, entities, now = new Date('2026-11-01T12:00:00Z') }) {
  const notebookCount = Math.max(1, Math.ceil(entities / ENTITIES_PER_NOTEBOOK));
  const out = { notebooks: [], entities: [], relations: [], entries: [], embeddings: [] };
  let next = 0;
  for (let n = 0; n < notebookCount; n++) {
    const started = new Date(now.getTime() - (notebookCount - n) * 86_400_000).toISOString();
    const id = randomUUID();
    const size = Math.min(ENTITIES_PER_NOTEBOOK, entities - next);
    out.notebooks.push({
      id, user_id: userId, title: `Session ${n + 1}`, title_source: 'auto', started_at: started,
      ended_at: new Date(Date.parse(started) + 20 * 60_000).toISOString(), entity_count: Math.max(0, size),
    });
    const ids = [];
    for (let k = 0; k < size; k++, next++) {
      const name = vocabularyName(next);
      const entityId = name.replace(' ', '-');
      ids.push(entityId);
      out.entities.push({
        id: entityId, user_id: userId, notebook_id: id, name, type: TYPES[next % TYPES.length],
        metadata: {}, mentions: 1 + (next % 3), first_seen: started, last_seen: started,
      });
      out.embeddings.push({
        notebook_id: id, entity_id: entityId, user_id: userId,
        embedding: JSON.stringify(unitVector(entityId)), embedding_model: 'gte-small@1',
        content_hash: createHash('sha256').update(name).digest('hex').slice(0, 16),
      });
    }
    for (let k = 1; k < ids.length; k++) {
      out.relations.push({
        id: `${ids[k - 1]}--${ids[k]}`, user_id: userId, notebook_id: id,
        source_id: ids[k - 1], target_id: ids[k], label: 'related_to',
      });
    }
    out.entries.push({
      user_id: userId, notebook_id: id, created_at: started, entity_ids: ids, relation_ids: [],
      text: ids.length ? `Talked about ${ids.map((x) => x.replace('-', ' ')).join(', ')}.` : 'A quiet day.',
    });
  }
  return out;
}

async function main() {
  const { localStack } = await import('./local.mjs');
  const { values } = parseArgs({ options: { entities: { type: 'string' }, email: { type: 'string' }, cleanup: { type: 'boolean' } } });
  const stack = localStack();
  const users = async () => ((await stack.call('/auth/v1/admin/users?per_page=1000')).users ?? [])
    .filter((u) => isTimingEmail(u.email));

  if (values.cleanup) {
    const found = await users();
    for (const u of found) await stack.call(`/auth/v1/admin/users/${u.id}`, { method: 'DELETE' });
    console.error(`deleted ${found.length} timing-eval users`);
    return;
  }
  const entities = Number(values.entities);
  if (!Number.isInteger(entities) || entities < 0) throw new Error('--entities must be a whole number');
  const password = process.env.TIMING_USER_PASSWORD;
  if (!password) throw new Error('set TIMING_USER_PASSWORD');

  let email = values.email;
  let userId;
  if (email) {
    if (!isTimingEmail(email)) throw new Error('--email must be a timing-eval-*@example.test address');
    userId = (await users()).find((u) => u.email === email)?.id;
    if (!userId) throw new Error('no such timing-eval user');
    // Replace the history: entities, relations, entries, embeddings cascade.
    await stack.call(`/rest/v1/notebooks?user_id=eq.${userId}`, { method: 'DELETE' });
  } else {
    email = `timing-eval-${randomBytes(6).toString('hex')}@example.test`;
    userId = (await stack.call('/auth/v1/admin/users', {
      method: 'POST', body: { email, password, email_confirm: true },
    })).id;
  }
  const history = buildHistory({ userId, entities });
  const insert = async (table, rows) => {
    for (let i = 0; i < rows.length; i += 200) {
      await stack.call(`/rest/v1/${table}`, { method: 'POST', body: rows.slice(i, i + 200) });
    }
  };
  await insert('notebooks', history.notebooks);
  await insert('entities', history.entities);
  await insert('relations', history.relations);
  await insert('journal_entries', history.entries);
  await insert('entity_embeddings', history.embeddings);
  console.log(email);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().catch((error) => {
    console.error(`seed failed: ${error.message}`);
    process.exit(1);
  });
}
