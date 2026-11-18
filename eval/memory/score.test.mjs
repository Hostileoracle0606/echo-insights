import { test } from 'node:test';
import assert from 'node:assert/strict';
import { scoreProbe, summarize } from './score.mjs';

const item = (name, text = '') => ({ name, text, path: 'combined' });
const result = (over = {}) => ({
  retrieved: [], context: '', brief: null, extracted: [], ...over,
});

test('recall counts expected names found in retrieval, matching whole words of a longer name', () => {
  const s = scoreProbe(
    { expect_retrieved: ['Ridgeline', 'Tobias Wren'] },
    result({ retrieved: [item('Ridgeline Half Marathon'), item('Knee')], extracted: ['Ridgeline Half Marathon', 'Tobias Wren', 'Knee'] }),
  );
  assert.deepEqual(s.recall, [1, 2]);
  assert.deepEqual(s.misses, [{ name: 'Tobias Wren', why: 'not_retrieved' }]);
  assert.deepEqual(s.precision, [1, 2]);
  assert.equal(s.inserted, 1);
});

test('a name never extracted is an extraction miss and is left out of the recall denominator', () => {
  const s = scoreProbe({ expect_retrieved: ['Tobias Wren', 'Ridgeline'] },
    result({ retrieved: [item('Ridgeline')], extracted: ['Ridgeline'] }));
  assert.deepEqual(s.recall, [1, 1]);
  assert.deepEqual(s.misses, [{ name: 'Tobias Wren', why: 'not_extracted' }]);
});

test('a shorter name does not match a longer expected one ("Sam" is not "Sam Ortiz")', () => {
  const s = scoreProbe({ expect_retrieved: ['Sam Ortiz'] }, result({ retrieved: [item('Sam')], extracted: ['Sam'] }));
  assert.deepEqual(s.recall, [0, 0]);
  assert.deepEqual(s.misses, [{ name: 'Sam Ortiz', why: 'not_extracted' }]);
});

test('a forgotten name only in the brief is stale, attributed to the brief', () => {
  const s = scoreProbe({ expect_not_retrieved: ['Dana Whitfield'] },
    result({ retrieved: [item('Ruth Okafor')], brief: { text: 'Last time you had lunch with Dana Whitfield.' } }));
  assert.equal(s.stale, true);
  assert.deepEqual(s.staleIn, ['brief']);
});

test('a stale name in retrieval or its context counts against the retrieval path', () => {
  const s = scoreProbe({ expect_not_retrieved: ['Dayton'] },
    result({ retrieved: [item('Imogen')], context: '- Imogen --moved_to--> Dayton', brief: { text: 'Imogen is in Dalton.' } }));
  assert.deepEqual(s.staleIn, ['combined']);
});

test('stale_text is matched in active retrieved text, the context and the brief; nothing stale is false', () => {
  assert.deepEqual(scoreProbe({ expect_retrieved: ['Larkfield Bank'], stale_text: ['senior analyst'] },
    result({ retrieved: [item('Larkfield Bank', 'User is a senior analyst here.')], extracted: ['Larkfield Bank'] })).staleIn, ['combined']);
  const clean = scoreProbe({ expect_retrieved: ['Larkfield Bank'], stale_text: ['senior analyst'] },
    result({ retrieved: [item('Larkfield Bank', 'User is a staff analyst.')], extracted: ['Larkfield Bank'], brief: { text: 'staff analyst' } }));
  assert.equal(clean.stale, false);
  assert.equal(scoreProbe({ expect_retrieved: ['X'] }, result()).stale, null, 'no stale check on this probe');
});

test('status: decided is correct when a decided marker is present and no tentative one is', () => {
  const probe = { expect_retrieved: ['Northwind'], expect_status: 'decided', decided_markers: ['stay'], tentative_markers: ['might leave'] };
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Northwind', 'User decided_to_stay_at Northwind')] })).status, 'correct');
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Northwind', 'User might leave; decided to stay')] })).status, 'wrong');
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Northwind', 'Where the user works.')] })).status, 'wrong');
  assert.equal(scoreProbe({ expect_retrieved: ['N'] }, result()).status, 'n/a');
});

test('order: kept when the latest marker is in active text and every earlier one is still in what retrieval returns', () => {
  const probe = { expect_retrieved: ['Kyoto'], expect_order: ['Lisbon', 'Kyoto'] };
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Kyoto', 'trip to Kyoto'), item('Lisbon')], context: '- Lisbon\n- Kyoto' })).order, 'kept');
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Kyoto', 'trip to Kyoto')], context: '- Kyoto' })).order, 'lost');
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Lisbon', 'trip to Lisbon')], context: '- Lisbon' })).order, 'lost');
});

test('ambiguity: acknowledged when two distinct retrieved names share the token', () => {
  const probe = { expect_retrieved: ['Sam Ortiz'], expect_ambiguity: true, ambiguity_token: 'Sam' };
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Sam Ortiz'), item('Sam Lee')] })).ambiguity, 'acknowledged');
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Sam Ortiz'), item('Samantha')] })).ambiguity, 'missed');
  assert.equal(scoreProbe({ expect_retrieved: ['x'] }, result()).ambiguity, 'n/a');
});

test('summarize: counts per category and in total, never percentages alone', () => {
  const rows = [
    { scenario: 'a', category: 'deletion', probeIndex: 0, ...scoreProbe({ expect_not_retrieved: ['Dana Whitfield'] }, result({ brief: { text: 'Dana Whitfield' } })) },
    { scenario: 'a', category: 'deletion', probeIndex: 1, ...scoreProbe({ expect_retrieved: ['Ruth Okafor'] }, result({ retrieved: [item('Ruth Okafor')], extracted: ['Ruth Okafor'], brief: { text: 'hi' } })) },
    { scenario: 'b', category: 'continuity', probeIndex: 0, ...scoreProbe({ expect_retrieved: ['Maren', 'Tobias'] }, result({ retrieved: [item('Maren'), item('Bellport')], extracted: ['Maren', 'Bellport'] })) },
  ];
  const out = summarize(rows);
  assert.deepEqual(out.total.recall, { hit: 2, of: 2 });
  assert.deepEqual(out.total.extractionMisses, { count: 1, ofExpected: 3 });
  assert.deepEqual(out.total.precision, { hit: 2, of: 3 });
  assert.deepEqual(out.total.inserted, { items: 1, probes: 3 });
  assert.deepEqual(out.total.stale, { probes: 1, of: 1, retrieval: 0, brief: 1, briefChecked: 1 });
  assert.deepEqual(out.byCategory.deletion.stale, { probes: 1, of: 1, retrieval: 0, brief: 1, briefChecked: 1 });
  assert.deepEqual(out.byCategory.continuity.recall, { hit: 1, of: 1 });
  assert.equal(out.total.probes, 3);
});
