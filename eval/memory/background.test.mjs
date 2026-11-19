import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { BACKGROUND, backgroundRows, isBackground } from './background.mjs';
import { loadScenarios } from './scenario.mjs';

const words = (s) => String(s).toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 2);

test('the background set: about 50 entities, bg- ids, relations between its own entities only', () => {
  assert.ok(BACKGROUND.entities.length >= 45 && BACKGROUND.entities.length <= 60, `${BACKGROUND.entities.length}`);
  assert.ok(BACKGROUND.relations.length >= 30, `${BACKGROUND.relations.length} relations`);
  const ids = new Set(BACKGROUND.entities.map((e) => e.id));
  assert.equal(ids.size, BACKGROUND.entities.length);
  for (const id of ids) assert.match(id, /^bg-[a-z0-9-]+$/);
  for (const r of BACKGROUND.relations) {
    assert.ok(ids.has(r.source_id) && ids.has(r.target_id), r.id);
  }
});

test('the background set shares no word with any name a scenario mentions or expects', () => {
  const dir = fileURLToPath(new URL('./scenarios/', import.meta.url));
  const scenarioWords = new Set();
  for (const s of loadScenarios(dir)) {
    const names = [
      ...s.probes.flatMap((p) => [...(p.expect_retrieved ?? []), ...(p.expect_not_retrieved ?? []), ...(p.distractors ?? []), ...(p.related ?? [])]),
      ...(s.actions ?? []).map((a) => a.name),
    ];
    for (const n of names) for (const w of words(n)) scenarioWords.add(w);
  }
  for (const e of BACKGROUND.entities) {
    for (const w of [...words(e.name), ...words(e.description)]) {
      assert.ok(!scenarioWords.has(w), `background ${e.name} uses scenario word "${w}"`);
    }
  }
});

test('backgroundRows owns every row by the probe user and notebook; isBackground recognises the ids', () => {
  const { entities, relations } = backgroundRows({ userId: 'u', notebookId: 'n', now: '2026-11-01T00:00:00Z' });
  assert.ok(entities.every((e) => e.user_id === 'u' && e.notebook_id === 'n' && e.first_seen && e.last_seen));
  assert.ok(relations.every((r) => r.user_id === 'u' && r.notebook_id === 'n' && !r.superseded_at));
  assert.equal(isBackground('bg-sourdough-starter'), true);
  assert.equal(isBackground('maren'), false);
});
