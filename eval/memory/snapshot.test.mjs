import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { SNAPSHOT_TABLES, restoreSnapshot, snapshotDigest, takeSnapshot, toSnapshot } from './snapshot.mjs';
import { localStack } from './stack.mjs';

function rawGraph(userId = randomUUID(), notebookId = randomUUID()) {
  const entryA = randomUUID();
  const entryB = randomUUID();
  const owned = { user_id: userId, notebook_id: notebookId };
  return {
    userId,
    notebook: { id: notebookId, user_id: userId, title: 'Eval', title_source: 'auto', revision: 3,
      started_at: '2026-11-18T10:00:00+00:00', conversation_mode: 'just_talk', mode_context: {} },
    suppressionKey: '\\x00ff',
    rows: {
      journal_entries: [
        { ...owned, id: entryB, text: 'second', created_at: '2026-11-18T10:02:00+00:00', entity_ids: ['otto'], relation_ids: [] },
        { ...owned, id: entryA, text: 'first', created_at: '2026-11-18T10:01:00+00:00', entity_ids: ['maren'], relation_ids: [] },
      ],
      entities: [{ ...owned, id: 'maren', name: 'Maren', type: 'person', description: `sister of ${userId}`, metadata: {},
        mentions: 1, first_seen: '2026-11-18T10:01:00+00:00', last_seen: '2026-11-18T10:01:00+00:00', questions: null, description_source: 'extracted' }],
      relations: [{ ...owned, id: 'maren__runs__clayhouse', source_id: 'maren', target_id: 'clayhouse', label: 'runs',
        metadata: {}, created_at: '2026-11-18T10:01:00+00:00', superseded_at: '2026-11-18T10:02:00+00:00' }],
      entity_suppressions: [{ user_id: userId, entity_hash: 'abc', kind: 'forgotten', match_inside: false, name_words: 2, created_at: '2026-11-18T10:03:00+00:00' }],
      conversation_turns: [{ ...owned, turn_id: 's1-t1', speaker: 'user', text: 'first', spoken_at: '2026-11-18T10:01:00+00:00', input: 'typed' }],
    },
  };
}

test('SNAPSHOT_TABLES names the graph tables, parents first', () => {
  assert.deepEqual(SNAPSHOT_TABLES, ['notebooks', 'journal_entries', 'entities', 'relations', 'entity_suppressions', 'conversation_turns']);
});

test('toSnapshot removes the user and notebook ids and gives entries stable placeholders', () => {
  const raw = rawGraph();
  const snap = toSnapshot(raw);
  const text = JSON.stringify(snap);
  assert.ok(!text.includes(raw.userId), 'user id removed, even inside text');
  assert.ok(!text.includes(raw.notebook.id));
  for (const e of raw.rows.journal_entries) assert.ok(!text.includes(e.id));
  assert.deepEqual(snap.tables.journal_entries.map((e) => [e.id, e.text]), [['$entry-1', 'first'], ['$entry-2', 'second']]);
  assert.equal(snap.tables.relations[0].superseded_at, '2026-11-18T10:02:00+00:00');
  assert.equal(snap.notebook.revision, 3);
});

test('snapshotDigest: same graph under different uuids gives the same digest', () => {
  const a = toSnapshot(rawGraph());
  const b = toSnapshot(rawGraph());
  assert.equal(snapshotDigest(a), snapshotDigest(b));
  const changed = toSnapshot(rawGraph());
  changed.tables.relations[0].superseded_at = null;
  assert.notEqual(snapshotDigest(a), snapshotDigest(changed));
});

const stack = localStack(process.env);
test('round trip on the local stack: take → restore into a second user → take gives the same digest',
  { skip: stack ? false : 'needs a local Supabase stack (source eval/privacy/local-env.sh)' }, async () => {
    const users = [];
    try {
      const a = await stack.createUser(users);
      const b = await stack.createUser(users);
      const raw = rawGraph(a.id, randomUUID());
      const { notebookId } = await restoreSnapshot({ ...stack.admin, userId: a.id, snapshot: toSnapshot(raw) });
      const first = await takeSnapshot({ ...stack.admin, userId: a.id, notebookId });
      const restored = await restoreSnapshot({ ...stack.admin, userId: b.id, snapshot: first });
      const second = await takeSnapshot({ ...stack.admin, userId: b.id, notebookId: restored.notebookId });
      assert.equal(snapshotDigest(second), snapshotDigest(first));
      assert.equal(second.tables.relations[0].superseded_at.slice(0, 19), '2026-11-18T10:02:00');
      assert.equal(second.tables.entity_suppressions.length, 1);
      assert.equal(second.suppressionKey, '\\x00ff', 'the per-user suppression key travels with the graph');
      assert.equal(second.tables.journal_entries.length, 2);
    } finally {
      for (const id of users) await stack.deleteUser(id);
    }
  });
