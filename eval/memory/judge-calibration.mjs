// Hand-labelled cases the judge must get right before its verdicts are used.
// Each is a real scenario with a memory or brief written by hand to be
// clearly right or clearly wrong. If the judge disagrees with any label, the
// run still writes its verdicts but marks the judge "uncalibrated".

const imogen = 'correction-city-same-session';
const felix = 'correction-edit-description';
const northwind = 'changing-tentative-to-decided';
const sams = 'continuity-two-sams';

export const CALIBRATION = [
  { id: 'brief-denial-is-not-stale', kind: 'brief', scenario: imogen,
    brief: 'The person misspoke and corrected themselves: Imogen moved to Dalton, not Dayton. Ask how the move to Dalton went.',
    expect: { stale: 'clean' } },
  { id: 'brief-old-job-is-stale', kind: 'brief', scenario: felix,
    brief: 'Felix Navarro is a pediatric nurse at Saint Corin hospital. Felix invited them to his birthday dinner on Friday.',
    expect: { stale: 'stale' } },
  { id: 'retrieval-old-city-in-description', kind: 'probe', scenario: imogen, probeIndex: 0,
    retrieved: [
      { name: 'Imogen', text: 'My best friend Imogen moved to Dayton last month.\nImogen moved_to Dalton' },
      { name: 'Dayton', text: 'Imogen moved to Dayton last month.' },
    ],
    rule: { stale: false },
    expect: { stale: 'stale', status: 'wrong' } },
  { id: 'retrieval-corrected-city-only', kind: 'probe', scenario: imogen, probeIndex: 0,
    retrieved: [
      { name: 'Imogen', text: "The user's best friend, who moved to Dalton last month.\nImogen moved_to Dalton" },
      { name: 'Dalton', text: 'Imogen moved_to Dalton' },
    ],
    rule: { stale: false },
    expect: { stale: 'clean', status: 'correct' } },
  { id: 'order-kept', kind: 'probe', scenario: northwind, probeIndex: 0,
    retrieved: [{ name: 'Northwind', text: 'The user considered leaving Northwind over the commute, then decided to stay after talking with Priya.' }],
    rule: { stale: null },
    expect: { status: 'correct', order: 'kept' } },
  { id: 'order-lost', kind: 'probe', scenario: northwind, probeIndex: 0,
    retrieved: [{ name: 'Northwind', text: 'The user works at Northwind and decided to stay.' }],
    rule: { stale: null },
    expect: { status: 'correct', order: 'lost' } },
  { id: 'two-sams-distinct', kind: 'probe', scenario: sams, probeIndex: 0,
    retrieved: [
      { name: 'Sam Ortiz', text: 'Coworker who reviewed the design doc and liked the caching section.' },
      { name: 'Sam Lee', text: 'Climbing partner at Granite Hall who sent the purple route.' },
    ],
    rule: { stale: null },
    expect: { ambiguity: 'acknowledged' } },
  { id: 'two-sams-merged', kind: 'probe', scenario: sams, probeIndex: 0,
    retrieved: [{ name: 'Sam', text: 'Coworker who reviewed the design doc and goes bouldering at Granite Hall.' }],
    rule: { stale: null },
    expect: { ambiguity: 'missed' } },
];

/** Compares a judge verdict with a case's labels; returns the fields that disagree. */
export function disagreements(expect, verdict) {
  return Object.entries(expect).filter(([k, v]) => verdict[k] !== v).map(([k, v]) => ({ field: k, expected: v, got: verdict[k] }));
}
