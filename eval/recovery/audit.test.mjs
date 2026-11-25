import { test } from 'node:test';
import assert from 'node:assert/strict';
import { countDuplicates, auditUser, AUDITED_TABLES } from './audit.mjs';
import { localStack } from './local.mjs';

test('countDuplicates counts rows beyond the first per key', () => {
  const rows = [{ k: 'a' }, { k: 'a' }, { k: 'b' }, { k: 'a' }, { k: 'c' }];
  assert.equal(countDuplicates(rows, (r) => r.k), 2);
  assert.equal(countDuplicates([], (r) => r.k), 0);
});

test('audits exactly the five memory tables', () => {
  assert.deepEqual([...AUDITED_TABLES].sort(),
    ['conversation_turns', 'entities', 'journal_entries', 'relations', 'session_briefs']);
});

const stack = localStack(process.env);

test('integration: a seeded same-name entity reads as one duplicate', { skip: !stack && 'local Supabase env not set' }, async () => {
  const user = await stack.createUser();
  try {
    const notebook = await stack.insert('notebooks', { user_id: user.id, title: 'audit fixture', started_at: new Date().toISOString() });
    const now = new Date().toISOString();
    const entity = (id, name) => ({ id, user_id: user.id, notebook_id: notebook.id, name, type: 'organization', first_seen: now, last_seen: now });
    await stack.insert('entities', entity('northwind', 'Northwind'));
    await stack.insert('entities', entity('northwind-2', 'northwind'));
    await stack.insert('entities', entity('priya', 'Priya'));
    await stack.insert('journal_entries', { user_id: user.id, notebook_id: notebook.id, text: 'one', created_at: now });
    const result = await auditUser({ url: stack.url, adminHeaders: stack.admin, userId: user.id });
    assert.equal(result.counts.entities, 3);
    assert.equal(result.duplicates.entities, 1);
    assert.equal(result.counts.journal_entries, 1);
    assert.equal(result.duplicates.journal_entries, 0);
    for (const table of AUDITED_TABLES) assert.equal(typeof result.duplicates[table], 'number');
  } finally {
    await stack.deleteUser(user.id);
  }
});
