import assert from 'node:assert/strict';
import test from 'node:test';

import { namePool, SPLITS } from './names.mjs';
import { WorldSchema } from './schema.mjs';
import { FAMILIES, makeWorld } from './world.mjs';

const worlds = (split, n, start = 1) => Array.from({ length: n }, (_, i) => makeWorld({ seed: start + i, split }));

test('the same seed gives the same world; different seeds differ', () => {
  assert.deepEqual(makeWorld({ seed: 7, split: 'test' }), makeWorld({ seed: 7, split: 'test' }));
  assert.notDeepEqual(makeWorld({ seed: 7, split: 'test' }), makeWorld({ seed: 8, split: 'test' }));
});

test('every generated world validates against the schema and is labelled synthetic', () => {
  for (const w of worlds('train', 40)) {
    const parsed = WorldSchema.safeParse(w);
    assert.ok(parsed.success, `${w.id}: ${parsed.error?.issues?.[0]?.path?.join('.')} ${parsed.error?.issues?.[0]?.message}`);
    assert.equal(w.synthetic, true);
  }
});

test('each family a world uses contributes a query; only unanswerable has empty gold', () => {
  for (const w of worlds('test', 40)) {
    for (const family of w.families) {
      const qs = w.queries.filter((q) => q.family === family);
      assert.ok(qs.length >= 1, `${w.id} has no ${family} query`);
      for (const q of qs) {
        if (family === 'unanswerable') assert.deepEqual([q.gold.length, q.answerable], [0, false]);
        else assert.ok(q.gold.length > 0 && q.answerable, `${w.id} ${q.id}`);
      }
    }
  }
});

test('gold entity ids exist in the final graph', () => {
  for (const w of worlds('val', 30)) {
    const ids = new Set(w.finalGraph.entities.map((e) => e.id));
    for (const q of w.queries) for (const g of q.gold) assert.ok(ids.has(g.entityId), `${w.id} ${q.id} -> ${g.entityId}`);
  }
});

test('family shapes: superseded relation, shared first name, graded multi-hop gold', () => {
  const all = worlds('test', 80);
  const withFamily = (f) => all.filter((w) => w.families.includes(f));
  for (const f of FAMILIES) assert.ok(withFamily(f).length > 0, `no world uses ${f}`);
  for (const w of withFamily('temporal_change')) {
    assert.ok(w.finalGraph.relations.some((r) => r.supersededInSession != null), w.id);
  }
  for (const w of withFamily('ambiguity')) {
    const firsts = w.finalGraph.entities.filter((e) => e.type === 'person').map((e) => e.name.split(' ')[0]);
    assert.ok(firsts.length !== new Set(firsts).size, `${w.id} has no shared first name`);
  }
  for (const w of withFamily('multi_hop')) {
    const q = w.queries.find((x) => x.family === 'multi_hop');
    assert.ok(q.gold.some((g) => g.relevance === 2) && q.gold.some((g) => g.relevance === 1), w.id);
  }
});

test('no fact is stated before the session it belongs to, and every session states something', () => {
  for (const w of worlds('train', 30)) {
    w.sessions.forEach((s, i) => {
      assert.ok(s.facts.length + s.actions.length > 0, `${w.id} session ${i + 1} is empty`);
      for (const f of s.facts) assert.equal(f.session, i + 1);
    });
  }
});

test('train, val and test name pools are pairwise disjoint', () => {
  const pools = Object.fromEntries(SPLITS.map((s) => [s, namePool(s)]));
  for (const a of SPLITS) for (const b of SPLITS) {
    if (a >= b) continue;
    for (const kind of Object.keys(pools[a])) {
      const overlap = pools[a][kind].filter((n) => pools[b][kind].includes(n));
      assert.deepEqual(overlap, [], `${a}/${b} share ${kind}: ${overlap.join(', ')}`);
    }
  }
});

test('worlds only use names from their own split', () => {
  const pool = namePool('test');
  const allowed = new Set(Object.values(pool).flat());
  for (const w of worlds('test', 20)) {
    for (const e of w.finalGraph.entities) {
      for (const part of e.nameParts) assert.ok(allowed.has(part), `${w.id}: ${part} not from the test pool`);
    }
  }
});
