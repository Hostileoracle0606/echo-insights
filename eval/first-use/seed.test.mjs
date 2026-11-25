import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STUDY_EMAIL, assertLocal, emptyNotebookRow, remainingTotal, rowFilters } from './seed.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const ids = { userId: 'u-1', notebookIds: ['n-1', 'n-2'], sessionIds: ['s-1'] };

test('refuses any Supabase that is not on this machine', () => {
  for (const url of ['https://abc.supabase.co', 'http://10.0.0.5:55321', 'http://localhost.evil.com']) {
    assert.throws(() => assertLocal(url), /local Supabase only/, url);
  }
  for (const url of ['http://127.0.0.1:55321', 'http://localhost:55321', 'http://[::1]:55321']) {
    assert.equal(assertLocal(url), new URL(url).origin);
  }
});

test('the study account uses the reserved first-use test address', () => {
  assert.match(STUDY_EMAIL, /^first-use-[a-z0-9-]+@example\.test$/);
});

test('every table the migrations create has a filter for the study account', () => {
  const dir = resolve(root, 'supabase/migrations');
  const created = new Set();
  for (const file of readdirSync(dir)) {
    for (const m of readFileSync(resolve(dir, file), 'utf8').matchAll(/create table (?:if not exists )?public\.(\w+)/gi)) {
      created.add(m[1]);
    }
  }
  assert.ok(created.size > 10, 'found the migrations');
  assert.deepEqual(Object.keys(rowFilters(ids)).sort(), [...created].sort());
});

test('user tables filter by user id; child tables by their parent ids', () => {
  const f = rowFilters(ids);
  assert.equal(f.notebooks, 'user_id=eq.u-1');
  assert.equal(f.profiles, 'user_id=eq.u-1');
  assert.equal(f.conversation_runtime_inbox, 'session_id=in.(s-1)');
  assert.equal(f.notebook_commit_requests, 'notebook_id=in.(n-1,n-2)');
  assert.equal(f.retrieve_rate_limits, 'scope=in.("user:u-1","notebook:n-1","notebook:n-2")');
});

test('a child table with no parents left gets no filter, and so is counted as 0', () => {
  const f = rowFilters({ userId: 'u-1', notebookIds: [], sessionIds: [] });
  assert.equal(f.conversation_runtime_inbox, null);
  assert.equal(f.notebook_commit_requests, null);
  assert.equal(f.retrieve_rate_limits, 'scope=in.("user:u-1")');
});

test('remainingTotal adds every count, including the auth user', () => {
  assert.equal(remainingTotal({ authUser: 0, notebooks: 0, entities: 0 }), 0);
  assert.equal(remainingTotal({ authUser: 1, notebooks: 0 }), 1);
  assert.equal(remainingTotal({ authUser: 0, notebooks: 2, relations: 3 }), 5);
});

test('the seeded notebook is the same empty row the app creates for a new user', () => {
  const row = emptyNotebookRow('u-1', new Date('2026-11-20T10:00:00Z'));
  assert.deepEqual(row, {
    user_id: 'u-1', title: 'Untitled', started_at: '2026-11-20T10:00:00.000Z',
    conversation_mode: 'just_talk', mode_context: {},
  });
});
