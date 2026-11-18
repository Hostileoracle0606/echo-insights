import { test } from 'node:test';
import assert from 'node:assert/strict';
import { briefText, retrievedItems } from './probe.mjs';

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
