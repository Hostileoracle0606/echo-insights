import assert from 'node:assert/strict';
import test from 'node:test';

import { snapshotDigest } from '../../memory/snapshot.mjs';
import { makeWorld } from '../gen/world.mjs';
import { assertEmbedded, goldSnapshot, scoreQuery } from './oracle.mjs';

test('the gold snapshot is deterministic and holds exactly the final graph', () => {
  const w = makeWorld({ seed: 20011, split: 'test' });
  const a = goldSnapshot(w);
  assert.equal(snapshotDigest(a), snapshotDigest(goldSnapshot(w)));
  assert.deepEqual(a.tables.entities.map((e) => e.id).sort(), w.finalGraph.entities.map((e) => e.id).sort());
  for (const e of a.tables.entities) assert.ok(e.description.length > 0 && e.description_source === 'extracted');
});

test('superseded relations are kept with superseded_at, active ones are not superseded', () => {
  const w = makeWorld({ seed: 20012, split: 'test', families: ['temporal_change'] });
  const rels = goldSnapshot(w).tables.relations;
  assert.ok(rels.some((r) => r.superseded_at !== null));
  assert.ok(rels.some((r) => r.superseded_at === null));
  for (const r of rels) assert.equal(r.id, `${r.source_id}__${r.label}__${r.target_id}`);
});

test('a superseded fact is not in the current description', () => {
  const w = makeWorld({ seed: 20012, split: 'test', families: ['temporal_change'] });
  const moved = w.finalGraph.relations.find((r) => r.supersededInSession != null);
  const oldTown = w.finalGraph.entities.find((e) => e.id === moved.target).name;
  const person = goldSnapshot(w).tables.entities.find((e) => e.id === moved.source);
  assert.ok(!person.description.includes(`lives in ${oldTown}`));
});

test('hybrid refuses to rank when any world entity lacks an embedding for one model', () => {
  const ids = ['a', 'b'];
  assert.doesNotThrow(() => assertEmbedded([{ entity_id: 'a', embedding_model: 'gte-small@1' }, { entity_id: 'b', embedding_model: 'gte-small@1' }, { entity_id: 'bg-1', embedding_model: 'gte-small@1' }], ids));
  assert.throws(() => assertEmbedded([{ entity_id: 'a', embedding_model: 'gte-small@1' }], ids), /missing.*b/);
  assert.throws(() => assertEmbedded([{ entity_id: 'a', embedding_model: 'x@1' }, { entity_id: 'b', embedding_model: 'y@1' }], ids), /model/);
});

test('unanswerable queries get no rank metrics; answerable ones get recall, MRR and NDCG', () => {
  const unanswerable = { gold: [], answerable: false };
  assert.equal(scoreQuery(['a', 'b'], unanswerable), null);
  const q = { gold: [{ entityId: 'b', relevance: 2 }, { entityId: 'c', relevance: 1 }], answerable: true };
  const s = scoreQuery(['a', 'b', 'c'], q);
  assert.deepEqual([s.recallAt1, s.recallAt5, s.recallAt10, s.mrr], [0, 1, 1, 0.5]);
  assert.ok(s.ndcg10 > 0 && s.ndcg10 < 1);
});
