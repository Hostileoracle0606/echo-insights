import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildHistory, isTimingEmail, ENTITIES_PER_NOTEBOOK } from './seed.mjs';

const userId = '00000000-0000-4000-8000-000000000001';

test('empty history: one notebook, nothing in it', () => {
  const h = buildHistory({ userId, entities: 0 });
  assert.equal(h.notebooks.length, 1);
  assert.equal(h.notebooks[0].entity_count, 0);
  assert.deepEqual([h.entities.length, h.relations.length, h.embeddings.length], [0, 0, 0]);
});

test('500 entities spread over notebooks, each entity embedded once', () => {
  const h = buildHistory({ userId, entities: 500 });
  assert.equal(h.entities.length, 500);
  assert.equal(h.notebooks.length, 500 / ENTITIES_PER_NOTEBOOK);
  assert.equal(h.embeddings.length, 500);
  assert.equal(new Set(h.entities.map((e) => `${e.notebook_id}/${e.id}`)).size, 500);
  assert.equal(new Set(h.entities.map((e) => e.name)).size, 500);
  const counts = h.notebooks.map((nb) => nb.entity_count);
  assert.equal(counts.reduce((a, b) => a + b, 0), 500);
  for (const nb of h.notebooks) {
    assert.equal(h.entities.filter((e) => e.notebook_id === nb.id).length, nb.entity_count);
  }
});

test('relations join entities within a notebook only', () => {
  const h = buildHistory({ userId, entities: 50 });
  const where = new Map(h.entities.map((e) => [e.id, e.notebook_id]));
  assert.ok(h.relations.length >= 40);
  for (const r of h.relations) {
    assert.equal(where.get(r.source_id), r.notebook_id);
    assert.equal(where.get(r.target_id), r.notebook_id);
  }
});

test('every notebook has an earlier entry, so it opens quietly', () => {
  const h = buildHistory({ userId, entities: 50 });
  assert.equal(h.entries.length, h.notebooks.length);
});

test('embeddings are 384-dim unit vectors and deterministic', () => {
  const a = buildHistory({ userId, entities: 10 });
  const b = buildHistory({ userId, entities: 10 });
  const v = JSON.parse(a.embeddings[0].embedding);
  assert.equal(v.length, 384);
  assert.ok(Math.abs(Math.hypot(...v) - 1) < 1e-9);
  assert.equal(a.embeddings[3].embedding, b.embeddings[3].embedding);
  assert.equal(a.embeddings[0].embedding_model, 'gte-small@1');
});

test('only synthetic vocabulary: every row belongs to the user', () => {
  const h = buildHistory({ userId, entities: 50 });
  for (const rows of [h.notebooks, h.entities, h.relations, h.entries, h.embeddings]) {
    for (const row of rows) assert.equal(row.user_id, userId);
  }
  assert.match(h.entities[0].name, /^[a-z]+ [a-z]+$/);
});

test('only timing-eval addresses are ever touched', () => {
  assert.ok(isTimingEmail('timing-eval-0a1b2c@example.test'));
  assert.ok(!isTimingEmail('memory-eval-0a1b2c@example.test'));
  assert.ok(!isTimingEmail('timing-eval-0a1b2c@example.com'));
  assert.ok(!isTimingEmail('someone@gmail.com'));
});
