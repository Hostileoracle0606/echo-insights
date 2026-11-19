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

test('order: kept when the latest marker is in active text and every earlier one survives as a statement', () => {
  const probe = { expect_retrieved: ['Kyoto'], expect_order: ['Lisbon', 'Kyoto'] };
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Kyoto', 'trip to Kyoto, after cancelling Lisbon')] })).order, 'kept');
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

// ── Fix pass after the whole-branch review ─────────────────────────────────

test('rank: recall@1 and @3 use the ranked list, and a probe whose k covers the whole graph is flagged', () => {
  const s = scoreProbe({ expect_retrieved: ['Maren', 'Clayhouse'] },
    result({ retrieved: [item('Bellport'), item('Maren'), item('Kiln room'), item('Clayhouse')], extracted: ['Bellport', 'Maren', 'Kiln room', 'Clayhouse'] }));
  assert.equal(s.firstRank, 2);
  assert.deepEqual(s.recallAt1, [0, 2]);
  assert.deepEqual(s.recallAt3, [1, 2]);
  assert.equal(s.coversGraph, true);
  assert.equal(scoreProbe({ expect_retrieved: ['Maren'] },
    result({ retrieved: [item('Maren')], extracted: ['Maren', 'Bellport'] })).coversGraph, false);
});

test('order: an earlier state that survives only as a bare entity name is not a preserved sequence', () => {
  const probe = { expect_retrieved: ['Kyoto'], expect_order: ['Lisbon', 'Kyoto'] };
  // The Lisbon relation is superseded and nothing says the trip was earlier: only the name is left.
  assert.equal(scoreProbe(probe, result({ retrieved: [item('Kyoto', 'User to Kyoto'), item('Lisbon', '')], context: '- Lisbon (place)\n- Kyoto' })).order, 'lost');
  // The superseded relation is carried as history: the earlier state is recorded as earlier.
  assert.equal(scoreProbe(probe, result({ retrieved: [{ ...item('Kyoto', 'User to Kyoto'), history: '' }, { ...item('Lisbon', ''), history: 'User to Lisbon' }] })).order, 'kept');
});

test('a stale check is vacuous when the scripted action never applied', () => {
  const s = scoreProbe({ expect_not_retrieved: ['Dana Whitfield'] }, result({ retrieved: [item('Ruth Okafor')] }), { actionsApplied: false });
  assert.equal(s.stale, null);
  assert.equal(s.staleVacuous, true);
});

test('a name-only stale check is vacuous when the name was never in the graph and no action ran', () => {
  const s = scoreProbe({ expect_retrieved: ['Imogen'], expect_not_retrieved: ['Dayton'] },
    result({ retrieved: [item('Imogen')], extracted: ['Imogen', 'Dalton'] }));
  assert.equal(s.stale, null);
  assert.equal(s.staleVacuous, true);
});

test('a similar-name distractor is scored as confusion, not as stale resurfacing', () => {
  const probe = { expect_retrieved: ['Priya Shah'], distractors: ['Priyanka Rao'] };
  const s = scoreProbe(probe, result({ retrieved: [item('Priya Shah'), item('Priyanka Rao')], extracted: ['Priya Shah', 'Priyanka Rao'] }));
  assert.equal(s.confused, true);
  assert.equal(s.stale, null);
  assert.equal(s.inserted, 0, 'a retrieved distractor is counted as confusion, not as an unrelated insertion');
});

test('summarize: the brief is tallied once per scenario, and rank and confusion are summed', () => {
  const stalePr = (i) => ({ scenario: 'city', category: 'correction', probeIndex: i,
    ...scoreProbe({ expect_retrieved: ['Imogen'], stale_text: ['Dayton'] }, result({ retrieved: [item('Imogen')], extracted: ['Imogen'], brief: { text: 'Dayton' } })) });
  const rows = [stalePr(0), stalePr(1), stalePr(2),
    { scenario: 'felix', category: 'correction', probeIndex: 0, ...scoreProbe({ expect_retrieved: ['Felix'], stale_text: ['nurse'] }, result({ retrieved: [item('Felix')], extracted: ['Felix'], brief: { text: 'therapist' } })) },
    { scenario: 'names', category: 'changing_facts', probeIndex: 0, ...scoreProbe({ expect_retrieved: ['Priya Shah'], distractors: ['Priyanka Rao'] }, result({ retrieved: [item('Priyanka Rao'), item('Priya Shah')], extracted: ['Priya Shah', 'Priyanka Rao'] })) }];
  const out = summarize(rows);
  assert.deepEqual(out.total.briefs, { stale: 1, of: 2 });
  assert.deepEqual(out.total.recallAt1, { hit: 4, of: 5 });
  assert.deepEqual(out.total.coversGraph, { probes: 5, of: 5 });
  assert.deepEqual(out.total.distractors, { confused: 1, of: 1 });
});

// ── Negation-aware staleness (2026-11-19) ──────────────────────────────────

const IMOGEN_BRIEF = 'Best friend Imogen moved to Dalton last month.\nHey, good to hear from you. How are things with Imogen\'s move to Dalton?\nThe person misspoke and corrected themselves, saying their best friend Imogen moved to Dalton, not Dayton. This is a good opportunity to acknowledge the correction and ask about Imogen\'s move.';
const FELIX_BRIEF = 'Felix Navarro is a pediatric nurse at Saint Corin hospital.\nFelix invited them to his birthday dinner on Friday.';

test('a brief that names the old fact only to deny it is not stale (Imogen: "Dalton, not Dayton")', () => {
  const s = scoreProbe({ expect_retrieved: ['Imogen'], stale_text: ['Dayton'] },
    result({ retrieved: [item('Imogen')], extracted: ['Imogen'], brief: { text: IMOGEN_BRIEF } }));
  assert.deepEqual(s.staleIn, []);
});

test('a brief that states the old fact is stale (Felix: "pediatric nurse")', () => {
  const s = scoreProbe({ expect_retrieved: ['Felix Navarro'], stale_text: ['pediatric nurse'] },
    result({ retrieved: [item('Felix Navarro')], extracted: ['Felix Navarro'], brief: { text: FELIX_BRIEF } }));
  assert.deepEqual(s.staleIn, ['brief']);
});

test('negation is per occurrence: the denied term is excused, the asserted one is not', () => {
  const brief = (text) => scoreProbe({ expect_retrieved: ['Imogen'], stale_text: ['Dayton'] },
    result({ retrieved: [item('Imogen')], extracted: ['Imogen'], brief: { text } })).staleIn;
  assert.deepEqual(brief('Imogen moved to Dayton, not Dalton.'), ['brief']);
  assert.deepEqual(brief('She lives in Dalton instead of Dayton.'), []);
  assert.deepEqual(brief('I said Dayton earlier but I misspoke.'), []);
  assert.deepEqual(brief('Imogen moved to Dayton. Not sure when she started the new job.'), ['brief'],
    'a "not" in another sentence excuses nothing');
});

test('negation applies to retrieval text too: a description that records the correction is not stale', () => {
  const s = scoreProbe({ expect_retrieved: ['Imogen'], stale_text: ['Dayton'] },
    result({ retrieved: [item('Imogen', 'Moved to Dalton (not Dayton) last month.')], extracted: ['Imogen'] }));
  assert.deepEqual(s.staleIn, []);
  const still = scoreProbe({ expect_retrieved: ['Imogen'], stale_text: ['Dayton'] },
    result({ retrieved: [item('Imogen', 'My best friend Imogen moved to Dayton last month.')], extracted: ['Imogen'] }));
  assert.deepEqual(still.staleIn, ['combined']);
});
