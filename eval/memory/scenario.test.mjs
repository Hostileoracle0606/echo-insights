import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CATEGORIES, loadScenarios } from './scenario.mjs';

const valid = () => ({
  id: 'job-change-decided',
  category: 'changing_facts',
  sessions: [
    { turns: ['I might leave Northwind, the commute is killing me.'] },
    { turns: ['Talked it over with Priya. I decided to stay at Northwind.'] },
  ],
  actions: [{ after_session: 1, kind: 'forget', name: 'Priya Raman' }],
  probes: [{
    ask: 'What happened with the job thing?', expect_retrieved: ['Northwind'],
    expect_not_retrieved: ['Priyanka'], expect_status: 'decided',
    decided_markers: ['stay'], tentative_markers: ['might leave'], expect_ambiguity: false,
  }],
});

function dirWith(name, scenario) {
  const dir = mkdtempSync(join(tmpdir(), 'memory-scenarios-'));
  writeFileSync(join(dir, name), JSON.stringify(scenario));
  return dir;
}

test('a valid scenario loads', () => {
  const [s] = loadScenarios(dirWith('ok.json', valid()));
  assert.equal(s.id, 'job-change-decided');
  assert.equal(s.sessions.length, 2);
});

const broken = {
  'missing probes': (s) => { delete s.probes; },
  'unknown category': (s) => { s.category = 'vibes'; },
  'action after the last session': (s) => { s.actions[0].after_session = 3; },
  'probe with nothing to check': (s) => {
    s.probes[0].expect_retrieved = [];
    delete s.probes[0].expect_not_retrieved;
  },
  'ambiguity expected with no token to look for': (s) => { s.probes[0].expect_ambiguity = true; },
  'stale_text that is not a list of strings': (s) => { s.probes[0].stale_text = 'senior'; },
};
for (const [label, breakIt] of Object.entries(broken)) {
  test(`${label} throws naming the file`, () => {
    const s = valid();
    breakIt(s);
    assert.throws(() => loadScenarios(dirWith('bad-file.json', s)), /bad-file\.json/);
  });
}

test('the shipped corpus: 12 scenarios, 4/3/2/3 by category, at least 45 probes', () => {
  const dir = fileURLToPath(new URL('./scenarios/', import.meta.url));
  const scenarios = loadScenarios(dir);
  assert.equal(scenarios.length, 12);
  const counts = Object.fromEntries(CATEGORIES.map((c) => [c, scenarios.filter((s) => s.category === c).length]));
  assert.deepEqual(counts, { continuity: 4, correction: 3, deletion: 2, changing_facts: 3 });
  const probes = scenarios.reduce((n, s) => n + s.probes.length, 0);
  assert.ok(probes >= 45, `${probes} probes`);
  const sessions = scenarios.reduce((n, s) => n + s.sessions.length, 0);
  const turns = scenarios.reduce((n, s) => n + s.sessions.reduce((m, x) => m + x.turns.length, 0), 0);
  assert.ok(sessions / 12 <= 2.5, `avg sessions ${sessions / 12}`);
  assert.ok(turns / sessions <= 1.5, `avg turns ${turns / sessions}`);
  assert.equal(new Set(scenarios.map((s) => s.id)).size, 12);
});
