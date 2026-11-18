import { test } from 'node:test';
import assert from 'node:assert/strict';
import { briefText, embedNotebook, retrievedItems } from './probe.mjs';

const state = {
  entities: {
    northwind: { id: 'northwind', name: 'Northwind', description: 'Where the user works.' },
    priya: { id: 'priya', name: 'Priya', description: '' },
  },
  relations: {
    'user__might_leave__northwind': { id: 'user__might_leave__northwind', source: 'user', target: 'northwind', label: 'might leave', supersededAt: '2026-11-18T10:00:00Z' },
    'user__decided_to_stay_at__northwind': { id: 'user__decided_to_stay_at__northwind', source: 'user', target: 'northwind', label: 'decided to stay at' },
  },
};

test('retrieved items keep the service order, carry active relation text only, and say the path is combined', () => {
  const items = retrievedItems(state, ['northwind', 'priya', 'gone']);
  assert.deepEqual(items.map((i) => [i.name, i.path]), [['Northwind', 'combined'], ['Priya', 'combined']]);
  assert.match(items[0].text, /Where the user works\./);
  assert.match(items[0].text, /decided to stay at/);
  assert.doesNotMatch(items[0].text, /might leave/, 'a superseded relation is not current memory');
});

test('briefText joins every string in the saved brief', () => {
  assert.equal(briefText({ openingLine: 'Hi again.', focus: ['Northwind', 'the commute'], n: 3 }), 'Hi again.\nNorthwind\nthe commute');
  assert.equal(briefText(null), null);
});

test('embedNotebook retries a 5xx (the edge runtime cancels a cold model load at its CPU limit)', async () => {
  const statuses = [502, 200];
  const calls = [];
  const waits = [];
  await embedNotebook({
    url: 'http://127.0.0.1:55321', secret: 's', notebookId: 'nb',
    fetchImpl: async (url, init) => {
      calls.push(init.headers['x-internal-secret']);
      const status = statuses.shift();
      return new Response(JSON.stringify(status === 200 ? { ok: true } : { error: 'x' }), { status });
    },
    sleep: async (ms) => { waits.push(ms); },
  });
  assert.deepEqual(calls, ['s', 's']);
  assert.deepEqual(waits, [2000]);
});

test('embedNotebook fails loudly after 3 attempts, or at once on ok:false', async () => {
  let n = 0;
  await assert.rejects(embedNotebook({ url: 'http://x', secret: 's', notebookId: 'nb',
    fetchImpl: async () => { n += 1; return new Response('{}', { status: 502 }); }, sleep: async () => {} }), /embed-entities → 502/);
  assert.equal(n, 3);
  await assert.rejects(embedNotebook({ url: 'http://x', secret: 's', notebookId: 'nb',
    fetchImpl: async () => new Response('{"ok":false,"stage":"notebook"}', { status: 200 }), sleep: async () => {} }), /notebook/);
});

test('retrieved items carry superseded relations separately as history, never as current text', () => {
  const [northwind] = retrievedItems(state, ['northwind']);
  assert.equal(northwind.history, 'user might leave Northwind');
  assert.doesNotMatch(northwind.text, /might leave/);
});
