import assert from 'node:assert/strict';
import test from 'node:test';

import { admissionOutcomes, goldEntities, matchEntities, pairF1, worldToScenario } from './match.mjs';
import { makeWorld } from '../gen/world.mjs';

const gold = [
  { id: 'kiran-rutherford', name: 'Kiran Rutherford', aliases: ['Kiran'], type: 'person' },
  { id: 'westmoor', name: 'Westmoor', aliases: [], type: 'place' },
  { id: 'westmere', name: 'Westmere', aliases: [], type: 'place' },
];

test('a first-name alias matches a person when no other gold person shares it', () => {
  const m = matchEntities([{ id: 'kiran', name: 'Kiran' }, { id: 'westmoor', name: 'westmoor' }, { id: 'shift', name: 'night shift' }], gold);
  assert.deepEqual([m.tp, m.fp, m.fn], [2, 1, 1]);
  assert.equal(m.map.get('kiran'), 'kiran-rutherford');
});

test('a shared first name does not match either person by alias', () => {
  const twins = [
    { id: 'sam-ortiz', name: 'Sam Ortiz', aliases: ['Sam'], type: 'person' },
    { id: 'sam-lee', name: 'Sam Lee', aliases: ['Sam'], type: 'person' },
  ];
  const m = matchEntities([{ id: 'sam', name: 'Sam' }], twins);
  assert.deepEqual([m.tp, m.fp, m.fn], [0, 1, 2]);
});

test('relation pair F1 ignores direction and label, scores which two things are connected', () => {
  const map = new Map([['k', 'kiran-rutherford'], ['w', 'westmoor']]);
  const r = pairF1([{ source: 'w', label: 'hometown_of', target: 'k' }], [{ source: 'kiran-rutherford', label: 'grew_up_in', target: 'westmoor' }, { source: 'kiran-rutherford', label: 'lives_in', target: 'westmere' }], map);
  assert.deepEqual([r.tp, r.fp, r.fn], [1, 0, 1]);
});

const state = (entities) => ({ entities: Object.fromEntries(entities.map((e) => [e.id, e])), relations: {}, entries: [], followUps: [], askedQuestions: [] });

test('a whole-turn invalidChange marks every valid item of the turn rejected', () => {
  const out = admissionOutcomes({
    patch: { entities: [{ name: 'Kiran Rutherford' }, { name: 'Westmoor' }] },
    commit: { status: 'rejected', code: 'invalidChange' },
    before: state([]), after: state([]), gold,
  });
  assert.deepEqual(out.map((o) => o.outcome), ['rejected', 'rejected']);
});

test('persisted, merged into the right entity, merged into the wrong one', () => {
  const before = state([{ id: 'kiran-rutherford', name: 'Kiran Rutherford' }]);
  const after = state([{ id: 'kiran-rutherford', name: 'Kiran Rutherford' }, { id: 'westmere', name: 'Westmere' }]);
  const out = admissionOutcomes({
    patch: { entities: [{ name: 'Kiran' }, { name: 'Westmoor' }, { name: 'Westmere' }] },
    commit: { status: 'committed', code: null }, before, after, gold,
    idFor: (name) => ({ Kiran: 'kiran-rutherford', Westmoor: 'westmere', Westmere: 'westmere' })[name],
  });
  assert.deepEqual(out.map((o) => [o.gold, o.outcome]), [
    ['kiran-rutherford', 'merged_correct'], ['westmoor', 'merged_wrong'], ['westmere', 'persisted'],
  ]);
});

test('extracted items that match no gold entity are not admission items', () => {
  const out = admissionOutcomes({ patch: { entities: [{ name: 'night shift' }] }, commit: { status: 'committed' }, before: state([]), after: state([]), gold });
  assert.deepEqual(out, []);
});

test('worldToScenario keeps session order, turn text, and removal actions after their session', () => {
  const world = makeWorld({ seed: 4, split: 'test', families: ['unanswerable', 'paraphrase'] });
  const turns = world.sessions.flatMap((s, i) => s.facts.map((f) => ({ session: i + 1, text: f.statement, factIds: [f.id] })));
  const sc = worldToScenario(world, { turns });
  assert.equal(sc.sessions.length, world.sessions.length);
  assert.deepEqual(sc.sessions[0].turns, turns.filter((t) => t.session === 1).map((t) => t.text));
  const removal = world.sessions.findIndex((s) => s.actions.length);
  if (removal >= 0) assert.deepEqual(sc.actions.map((a) => a.after_session), [removal + 1]);
  assert.ok(goldEntities(world).length >= world.finalGraph.entities.length);
});

test('typedMatches asks Claude once per call about label pairs and caches the answer', async () => {
  const { typedMatches } = await import('./match.mjs');
  const calls = [];
  const runner = { run: async (req) => { calls.push(req); return { output: { pairs: [{ index: 0, same: true }, { index: 1, same: false }] } }; } };
  const cache = new Map();
  const pairs = [{ gold: 'works_at', predicted: 'employed_by' }, { gold: 'lives_in', predicted: 'grew_up_in' }];
  const first = await typedMatches(runner, pairs, { get: (k) => cache.get(k), set: (k, v) => cache.set(k, v) });
  assert.deepEqual(first, [true, false]);
  assert.match(calls[0].prompt, /works_at/);
  const again = await typedMatches(runner, pairs, { get: (k) => cache.get(k), set: (k, v) => cache.set(k, v) });
  assert.deepEqual(again, [true, false]);
  assert.equal(calls.length, 1);
  assert.deepEqual(await typedMatches(runner, [], { get: () => undefined, set: () => {} }), []);
});
