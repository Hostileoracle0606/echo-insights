// Leakage and duplicate checks between benchmark splits.
// - near-duplicate: token-set Jaccard >= 0.8 (turns and questions)
// - shared 8-gram: any identical 8-word sequence (questions only; spoken filler
//   makes 8-grams between conversation turns common without being leakage)

export const normalize = (s) => String(s).toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '')
  .replace(/[^a-z0-9]+/g, ' ').trim();

const tokens = (s) => normalize(s).split(' ').filter(Boolean);

export function jaccard(a, b) {
  const A = new Set(tokens(a));
  const B = new Set(tokens(b));
  if (!A.size && !B.size) return 1;
  let inter = 0;
  for (const t of A) if (B.has(t)) inter += 1;
  return inter / (A.size + B.size - inter);
}

const grams = (s, n = 8) => {
  const t = tokens(s);
  const out = new Set();
  for (let i = 0; i + n <= t.length; i += 1) out.add(t.slice(i, i + n).join(' '));
  return out;
};

export function shared8gram(a, b) {
  const A = grams(a);
  for (const g of grams(b)) if (A.has(g)) return true;
  return false;
}

/** items: [{ id, kind: 'turn'|'query', text }]. Returns every cross-split collision. */
export function leakageReport(testItems, otherItems) {
  const report = [];
  const otherGrams = otherItems.filter((o) => o.kind === 'query').map((o) => ({ id: o.id, grams: grams(o.text) }));
  for (const t of testItems) {
    for (const o of otherItems) {
      if (jaccard(t.text, o.text) >= 0.8) report.push({ testId: t.id, otherId: o.id, reason: 'near-duplicate' });
    }
    if (t.kind !== 'query') continue;
    const mine = grams(t.text);
    for (const o of otherGrams) {
      if ([...mine].some((g) => o.grams.has(g)) && !report.some((r) => r.testId === t.id && r.otherId === o.id)) {
        report.push({ testId: t.id, otherId: o.id, reason: 'shared 8-gram' });
      }
    }
  }
  return report;
}

/** Keeps the first of any near-identical items (Jaccard >= 0.8) within one split. */
export function dedupe(items) {
  const kept = [];
  for (const item of items) if (!kept.some((k) => jaccard(k.text, item.text) >= 0.8)) kept.push(item);
  return kept;
}
