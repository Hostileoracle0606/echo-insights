import assert from 'node:assert/strict';
import test from 'node:test';

import { makeWorld } from './world.mjs';
import { PHRASING_SETS, WorldDropped, validateQueries, validateTurns, writeWorld } from './write.mjs';

const world = makeWorld({ seed: 3, split: 'test', families: ['temporal_change', 'distractor'] });

// A well-behaved writer: one turn per session that just says the statements.
const goodTurns = (w) => w.sessions.map((s, i) => ({ session: i + 1, text: s.facts.map((f) => f.statement).join(' '), factIds: s.facts.map((f) => f.id) }))
  .filter((t) => t.factIds.length);
const goodQueries = (w) => w.queries.map((q) => ({ id: q.id, text: `${q.intent.replace(/^Ask /, '').replace(/\.$/, '')}?` }));

function fakeRunner(replies) {
  const calls = [];
  return { calls, run: async (req) => { calls.push(req); const r = replies(req, calls.length); return { output: r, usage: {} }; } };
}
const memoryCache = () => { const m = new Map(); return { get: (k) => m.get(k), set: (k, v) => m.set(k, v), size: () => m.size }; };
const replyFor = (w, { turns = goodTurns(w), queries = goodQueries(w) } = {}) => (req) => (req.schema.properties.turns
  ? { turns: turns.filter((t) => t.session === JSON.parse(req.prompt.match(/<session>(\d+)<\/session>/)?.[1] ?? '0')).map(({ text, factIds }) => ({ text, factIds })) }
  : { queries });

test('a valid set of turns passes validation', () => {
  assert.deepEqual(validateTurns(world, goodTurns(world)), []);
});

test('a turn missing a name its fact needs fails', () => {
  const turns = goodTurns(world);
  const victim = turns.find((t) => t.text.includes('Winifred Tolliver'));
  victim.text = victim.text.replaceAll('Winifred Tolliver', 'my coworker').replaceAll('Winifred', 'she');
  assert.ok(validateTurns(world, turns).some((e) => /Winifred/.test(e)));
});

test('a first name alone satisfies a person mention', () => {
  const turns = goodTurns(world).map((t) => ({ ...t, text: t.text.replaceAll('Winifred Tolliver', 'Winifred') }));
  assert.deepEqual(validateTurns(world, turns), []);
});

test('a turn that states a later session\'s fact fails (future leakage)', () => {
  const move = world.sessions.flatMap((s) => s.facts).find((f) => f.supersedes);
  const newTown = world.finalGraph.entities.find((e) => e.id === move.object).name;
  const turns = goodTurns(world);
  assert.ok(turns[0].session < move.session, 'the move happens after the first turn');
  turns[0].text += ` Oh and they will move to ${newTown}.`;
  assert.ok(validateTurns(world, turns).some((e) => e.includes(newTown) && /later/.test(e)));
});

test('every fact must be claimed by exactly one turn', () => {
  const turns = goodTurns(world);
  turns[0].factIds = turns[0].factIds.slice(1);
  assert.ok(validateTurns(world, turns).some((e) => /not covered/.test(e)));
});

test('a query that uses a term it must avoid fails', () => {
  const w = makeWorld({ seed: 5, split: 'test', families: ['multi_hop'] });
  const qs = goodQueries(w);
  const q = w.queries[0];
  qs[0].text = `Is ${q.avoidTerms[0]} where it is?`;
  assert.ok(validateQueries(w, qs).some((e) => e.includes(q.avoidTerms[0])));
});

test('writeWorld returns validated turns and queries, sending the phrasing instruction for its split', async () => {
  const runner = fakeRunner(replyFor(world));
  const out = await writeWorld({ world, runner, cache: memoryCache() });
  assert.ok(out.turns.length >= 1 && out.queries.length === world.queries.length);
  const queryCall = runner.calls.find((c) => c.schema.properties.queries);
  assert.ok(PHRASING_SETS.test.some((p) => queryCall.prompt.includes(p)));
  assert.ok(!PHRASING_SETS.train.some((p) => queryCall.prompt.includes(p)));
});

test('after two bad regenerations the world is dropped, never patched', async () => {
  const bad = goodTurns(world).map((t) => ({ ...t, text: 'nothing useful' }));
  const runner = fakeRunner(replyFor(world, { turns: bad }));
  await assert.rejects(writeWorld({ world, runner, cache: memoryCache() }), WorldDropped);
  const firstSession = runner.calls.filter((c) => c.schema.properties.turns && c.prompt.includes('<session>1</session>'));
  assert.equal(firstSession.length, 3, 'one try and two regenerations');
});

test('a rerun with the same cache makes no runner calls', async () => {
  const cache = memoryCache();
  await writeWorld({ world, runner: fakeRunner(replyFor(world)), cache });
  const again = fakeRunner(replyFor(world));
  await writeWorld({ world, runner: again, cache });
  assert.equal(again.calls.length, 0);
});

test('phrasing sets for train, val and test share no instruction', () => {
  const all = [...PHRASING_SETS.train, ...PHRASING_SETS.val, ...PHRASING_SETS.test];
  assert.equal(new Set(all).size, all.length);
});
