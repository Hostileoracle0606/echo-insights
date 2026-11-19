// Scores one probe against what retrieval and the brief returned, and sums the
// scores into memory.json. Counts, never percentages alone. Text is compared
// as whole words, case- and punctuation-insensitive ("decided_to_stay_at"
// contains "stay").

const norm = (s) => ` ${String(s ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()} `;
const hasWords = (hay, needle) => norm(needle).trim() !== '' && norm(hay).includes(norm(needle));
// A retrieved name answers an expected one when it contains all of it:
// "Ridgeline Half Marathon" answers "Ridgeline"; "Sam" does not answer "Sam Ortiz".
const answers = (name, expected) => hasWords(name, expected);

// A stale term counts only where the text asserts it. Per occurrence, within
// its sentence: excused right after "not"/"never" (up to 3 words before),
// after "instead of"/"rather than"/"no longer", or anywhere in a sentence
// that says it is a correction ("misspoke", "corrected", "correction").
// "Dalton, not Dayton" denies Dayton; "Dayton, not Dalton" asserts it.
const CORRECTION_SENTENCE = /\b(misspoke|misspoken|corrected|correction|mistakenly)\b/;
const NEGATORS = new Set(['not', 'never']);
const PHRASES = ['instead of', 'rather than', 'no longer'];
export function asserts(hay, term) {
  const target = norm(term).trim().split(' ').filter(Boolean);
  if (!target.length) return false;
  for (const sentence of String(hay ?? '').split(/[.!?;\n]+/)) {
    const words = norm(sentence).trim().split(' ').filter(Boolean);
    const excusedSentence = CORRECTION_SENTENCE.test(words.join(' '));
    for (let i = 0; i + target.length <= words.length; i += 1) {
      if (!target.every((w, j) => words[i + j] === w)) continue;
      if (excusedSentence) continue;
      const before = words.slice(Math.max(0, i - 3), i);
      const lastTwo = words.slice(Math.max(0, i - 2), i).join(' ');
      if (before.some((w) => NEGATORS.has(w)) || PHRASES.includes(lastTwo)) continue;
      return true;
    }
  }
  return false;
}

/**
 * context.actionsApplied: undefined when the scenario has no scripted action,
 * else whether every action applied (a stale check after an action that never
 * ran tests nothing).
 */
export function scoreProbe(probe, result, { actionsApplied } = {}) {
  const retrieved = result.retrieved ?? [];
  const extracted = result.extracted ?? [];
  const context = result.context ?? '';
  const briefText = result.brief?.text ?? null;
  const activeText = retrieved.map((i) => `${i.name}\n${i.text}`).join('\n');

  const expected = probe.expect_retrieved ?? [];
  const misses = [];
  let hit = 0;
  let of = 0;
  for (const name of expected) {
    if (!extracted.some((e) => answers(e, name))) {
      misses.push({ name, why: 'not_extracted' });
      continue;
    }
    of += 1;
    if (retrieved.some((i) => answers(i.name, name))) hit += 1;
    else misses.push({ name, why: 'not_retrieved' });
  }
  const relevant = retrieved.filter((i) => expected.some((name) => answers(i.name, name))).length;
  const unwanted = probe.expect_not_retrieved ?? [];
  const flagged = retrieved.filter((i) => unwanted.some((name) => answers(i.name, name))).length;
  const distractors = probe.distractors ?? [];
  const confusedItems = retrieved.filter((i) => distractors.some((name) => answers(i.name, name))).length;

  // Ranking: small graphs mean k=8 often returns everything, so recall@8 alone
  // can't miss. recall@1/@3 and the first relevant rank use the order.
  const findable = expected.filter((name) => extracted.some((e) => answers(e, name)));
  const foundWithin = (n) => findable.filter((name) => retrieved.slice(0, n).some((i) => answers(i.name, name))).length;
  const firstIndex = retrieved.findIndex((i) => expected.some((name) => answers(i.name, name)));

  // Stale: a deleted/forgotten/corrected thing surfacing anywhere the person
  // or the voice model would see it.
  const staleText = probe.stale_text ?? [];
  const checksStale = unwanted.length > 0 || staleText.length > 0;
  const staleIn = [];
  if (checksStale) {
    const inRetrieval = flagged > 0 ||
      unwanted.some((name) => asserts(context, name)) ||
      staleText.some((t) => asserts(activeText, t) || asserts(context, t));
    const inBrief = briefText != null &&
      [...unwanted, ...staleText].some((t) => asserts(briefText, t));
    if (inRetrieval) staleIn.push(retrieved[0]?.path ?? 'combined');
    if (inBrief) staleIn.push('brief');
  }
  // Vacuous: the action never ran, or (no action) a name-only check whose
  // name was never in the graph — passing it would test nothing.
  const staleVacuous = checksStale && (actionsApplied === false || (
    actionsApplied === undefined && staleIn.length === 0 && staleText.length === 0 &&
    !unwanted.some((name) => extracted.some((e) => answers(e, name)))));
  if (staleVacuous) staleIn.length = 0;

  let status = 'n/a';
  if (probe.expect_status) {
    const [want, avoid] = probe.expect_status === 'tentative'
      ? [probe.tentative_markers ?? [], probe.decided_markers ?? []]
      : [probe.decided_markers ?? [], probe.tentative_markers ?? []];
    const texts = retrieved.map((i) => i.text);
    status = texts.some((t) => want.some((m) => hasWords(t, m))) &&
      !texts.some((t) => avoid.some((m) => hasWords(t, m))) ? 'correct' : 'wrong';
  }

  let order = 'n/a';
  if (probe.expect_order?.length) {
    const markers = probe.expect_order;
    const latest = markers[markers.length - 1];
    // Earlier states must survive as statements (descriptions, relations,
    // superseded history), not merely as a leftover entity name.
    const statements = retrieved.map((i) => `${i.text}\n${i.history ?? ''}`).join('\n');
    order = hasWords(activeText, latest) && markers.slice(0, -1).every((m) => hasWords(statements, m)) ? 'kept' : 'lost';
  }

  let ambiguity = 'n/a';
  if (probe.expect_ambiguity) {
    const names = new Set(retrieved.filter((i) => hasWords(i.name, probe.ambiguity_token)).map((i) => norm(i.name)));
    ambiguity = names.size >= 2 ? 'acknowledged' : 'missed';
  }

  return {
    recall: [hit, of],
    recallAt1: [foundWithin(1), findable.length],
    recallAt3: [foundWithin(3), findable.length],
    firstRank: firstIndex >= 0 ? firstIndex + 1 : null,
    coversGraph: retrieved.length >= extracted.length,
    precision: [relevant, retrieved.length],
    inserted: retrieved.length - relevant - flagged - confusedItems,
    confused: distractors.length ? confusedItems > 0 : null,
    stale: checksStale && !staleVacuous ? staleIn.length > 0 : null,
    staleVacuous,
    staleIn,
    briefChecked: checksStale && !staleVacuous && briefText != null,
    status,
    order,
    ambiguity,
    misses,
    expectedCount: expected.length,
  };
}

function emptyTally() {
  return {
    probes: 0,
    recall: { hit: 0, of: 0 },
    recallAt1: { hit: 0, of: 0 },
    recallAt3: { hit: 0, of: 0 },
    coversGraph: { probes: 0, of: 0 },
    distractors: { confused: 0, of: 0 },
    staleVacuous: 0,
    briefs: { stale: 0, of: 0 },
    extractionMisses: { count: 0, ofExpected: 0 },
    precision: { hit: 0, of: 0 },
    inserted: { items: 0, probes: 0 },
    stale: { probes: 0, of: 0, retrieval: 0, brief: 0, briefChecked: 0 },
    status: { correct: 0, of: 0 },
    order: { kept: 0, of: 0 },
    ambiguity: { acknowledged: 0, of: 0 },
  };
}

function add(t, s) {
  t.probes += 1;
  t.recall.hit += s.recall[0];
  t.recall.of += s.recall[1];
  t.recallAt1.hit += s.recallAt1[0];
  t.recallAt1.of += s.recallAt1[1];
  t.recallAt3.hit += s.recallAt3[0];
  t.recallAt3.of += s.recallAt3[1];
  t.coversGraph.of += 1;
  if (s.coversGraph) t.coversGraph.probes += 1;
  if (s.confused !== null) { t.distractors.of += 1; if (s.confused) t.distractors.confused += 1; }
  if (s.staleVacuous) t.staleVacuous += 1;
  t.extractionMisses.count += s.misses.filter((m) => m.why === 'not_extracted').length;
  t.extractionMisses.ofExpected += s.expectedCount;
  t.precision.hit += s.precision[0];
  t.precision.of += s.precision[1];
  t.inserted.items += s.inserted;
  t.inserted.probes += 1;
  if (s.stale !== null) {
    t.stale.of += 1;
    if (s.stale) t.stale.probes += 1;
    if (s.staleIn.some((p) => p !== 'brief')) t.stale.retrieval += 1;
    if (s.staleIn.includes('brief')) t.stale.brief += 1;
    if (s.briefChecked) t.stale.briefChecked += 1;
  }
  if (s.status !== 'n/a') { t.status.of += 1; if (s.status === 'correct') t.status.correct += 1; }
  if (s.order !== 'n/a') { t.order.of += 1; if (s.order === 'kept') t.order.kept += 1; }
  if (s.ambiguity !== 'n/a') { t.ambiguity.of += 1; if (s.ambiguity === 'acknowledged') t.ambiguity.acknowledged += 1; }
}

/** rows: [{scenario, category, probeIndex, ...scoreProbe()}] */
export function summarize(rows) {
  const total = emptyTally();
  const byCategory = {};
  for (const row of rows) {
    add(total, row);
    add((byCategory[row.category] ??= emptyTally()), row);
  }
  // One brief per scenario: tally it once, not once per probe.
  const briefs = new Map();
  for (const row of rows) {
    if (!row.briefChecked) continue;
    const b = briefs.get(row.scenario) ?? { category: row.category, stale: false };
    b.stale ||= row.staleIn.includes('brief');
    briefs.set(row.scenario, b);
  }
  for (const b of briefs.values()) {
    for (const t of [total, byCategory[b.category]]) {
      t.briefs.of += 1;
      if (b.stale) t.briefs.stale += 1;
    }
  }
  return { total, byCategory };
}
