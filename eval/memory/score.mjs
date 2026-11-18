// Scores one probe against what retrieval and the brief returned, and sums the
// scores into memory.json. Counts, never percentages alone. Text is compared
// as whole words, case- and punctuation-insensitive ("decided_to_stay_at"
// contains "stay").

const norm = (s) => ` ${String(s ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()} `;
const hasWords = (hay, needle) => norm(needle).trim() !== '' && norm(hay).includes(norm(needle));
// A retrieved name answers an expected one when it contains all of it:
// "Ridgeline Half Marathon" answers "Ridgeline"; "Sam" does not answer "Sam Ortiz".
const answers = (name, expected) => hasWords(name, expected);

export function scoreProbe(probe, result) {
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

  // Stale: a deleted/forgotten/corrected thing surfacing anywhere the person
  // or the voice model would see it.
  const staleText = probe.stale_text ?? [];
  const checksStale = unwanted.length > 0 || staleText.length > 0;
  const staleIn = [];
  if (checksStale) {
    const inRetrieval = flagged > 0 ||
      unwanted.some((name) => hasWords(context, name)) ||
      staleText.some((t) => hasWords(activeText, t) || hasWords(context, t));
    const inBrief = briefText != null &&
      [...unwanted, ...staleText].some((t) => hasWords(briefText, t));
    if (inRetrieval) staleIn.push(retrieved[0]?.path ?? 'combined');
    if (inBrief) staleIn.push('brief');
  }

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
    const everything = `${activeText}\n${context}`;
    order = hasWords(activeText, latest) && markers.slice(0, -1).every((m) => hasWords(everything, m)) ? 'kept' : 'lost';
  }

  let ambiguity = 'n/a';
  if (probe.expect_ambiguity) {
    const names = new Set(retrieved.filter((i) => hasWords(i.name, probe.ambiguity_token)).map((i) => norm(i.name)));
    ambiguity = names.size >= 2 ? 'acknowledged' : 'missed';
  }

  return {
    recall: [hit, of],
    precision: [relevant, retrieved.length],
    inserted: retrieved.length - relevant - flagged,
    stale: checksStale ? staleIn.length > 0 : null,
    staleIn,
    briefChecked: checksStale && briefText != null,
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
  return { total, byCategory };
}
