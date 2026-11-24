// Owner review of generated labels: a stratified sample, a self-contained
// local page to mark each item, and a tally recorded in the split manifest.
// Claude wrote the language, so a person checks it; items marked wrong are
// regenerated, never edited.

function rng(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

/** records: worlds.jsonl rows ({ world, written }). */
export function reviewSample(records, { perFamily = 10, seed = 1 } = {}) {
  const rand = rng(seed);
  const items = [];
  for (const { world, written } of records) {
    const names = new Map(world.finalGraph.entities.map((e) => [e.id, e.name]));
    const text = new Map(written.queries.map((q) => [q.id, q.text]));
    for (const q of world.queries) {
      if (!text.has(q.id)) continue;
      items.push({
        worldId: world.id, queryId: q.id, family: q.family, intent: q.intent,
        turns: written.turns.map((t) => ({ session: t.session, text: t.text })),
        question: text.get(q.id), answer: q.answer, answerable: q.answerable,
        gold: q.gold.map((g) => ({ name: names.get(g.entityId) ?? g.entityId, relevance: g.relevance })),
        sortKey: rand(),
      });
    }
  }
  const byFamily = new Map();
  for (const item of items.sort((a, b) => a.sortKey - b.sortKey)) {
    const list = byFamily.get(item.family) ?? [];
    if (list.length < perFamily) list.push(item);
    byFamily.set(item.family, list);
  }
  return [...byFamily.values()].flat().map(({ sortKey, ...item }) => item);
}

export function recordReview(sample, verdicts) {
  const ids = new Set(sample.map((s) => s.queryId));
  for (const [id, v] of Object.entries(verdicts)) {
    if (!ids.has(id)) throw new Error(`review: ${id} is not in the sample`);
    if (!['ok', 'wrong'].includes(v?.verdict)) throw new Error(`review: ${id} has verdict "${v?.verdict}"; use ok or wrong`);
  }
  const perFamily = {};
  const wrongIds = [];
  for (const s of sample) {
    const v = verdicts[s.queryId];
    const f = (perFamily[s.family] ??= { ok: 0, wrong: 0, unreviewed: 0, of: 0 });
    f.of += 1;
    if (!v) f.unreviewed += 1;
    else if (v.verdict === 'ok') f.ok += 1;
    else { f.wrong += 1; wrongIds.push(s.queryId); }
  }
  return { perFamily, wrongIds };
}

/** A self-contained page: open the file in a browser, mark items, download the verdicts JSON. */
export function reviewPage(sample) {
  const data = JSON.stringify(sample).replace(/</g, '\\u003c');
  return `<!doctype html><meta charset="utf-8"><title>Lumen benchmark review</title>
<style>body{font:15px/1.5 system-ui;max-width:820px;margin:24px auto;padding:0 16px;color:#1d1d1f}
.item{border:1px solid #ddd;border-radius:8px;padding:12px 16px;margin:16px 0}.turn{color:#444;margin:4px 0}
.q{font-weight:600;margin-top:8px}.meta{font-size:13px;color:#666}label{margin-right:16px}
textarea{width:100%;min-height:40px}button{font:inherit;padding:8px 14px}</style>
<h1>Benchmark review</h1>
<p><b>Synthetic data.</b> No real user wrote any of this. For each item, check that the conversation states what the labels assume, and that the question asks for the labelled answer. Mark <i>wrong</i> if either fails.</p>
<div id="items"></div><button id="dl">Download verdicts</button>
<script>
const sample = ${data};
const root = document.getElementById('items');
for (const s of sample) {
  const el = document.createElement('div'); el.className = 'item';
  const h = document.createElement('div'); h.className = 'meta'; h.textContent = s.family + ' · ' + s.queryId + ' · intent: ' + s.intent; el.append(h);
  for (const t of s.turns) { const p = document.createElement('div'); p.className = 'turn'; p.textContent = 'Session ' + t.session + ': ' + t.text; el.append(p); }
  const q = document.createElement('div'); q.className = 'q'; q.textContent = 'Q: ' + s.question; el.append(q);
  const g = document.createElement('div'); g.className = 'meta';
  g.textContent = 'Expected answer: ' + s.answer + (s.answerable ? '' : ' (unanswerable)') + ' · memories to retrieve: ' + (s.gold.map(x => x.name + (x.relevance === 2 ? ' (answers it)' : ' (needed)')).join(', ') || 'none');
  el.append(g);
  for (const v of ['ok', 'wrong']) { const l = document.createElement('label'); const r = document.createElement('input'); r.type = 'radio'; r.name = s.queryId; r.value = v; l.append(r, ' ' + v); el.append(l); }
  const n = document.createElement('textarea'); n.placeholder = 'Note (optional)'; n.dataset.id = s.queryId; el.append(n);
  root.append(el);
}
document.getElementById('dl').onclick = () => {
  const out = {};
  for (const s of sample) {
    const r = document.querySelector('input[name="' + s.queryId + '"]:checked');
    if (r) out[s.queryId] = { verdict: r.value, note: document.querySelector('textarea[data-id="' + s.queryId + '"]').value };
  }
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([JSON.stringify(out, null, 2)], { type: 'application/json' }));
  a.download = 'review-verdicts.json'; a.click();
};
</script>
`;
}
