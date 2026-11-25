// Matching extracted and stored memories to a world's ground truth.

const norm = (s) => String(s ?? '').toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, ' ').trim();

/** Every entity the history states, including ones later removed (extraction should still find them). */
export function goldEntities(world) {
  const removed = world.sessions.flatMap((s) => s.actions).map((a) => ({ id: a.entityId, name: a.name, aliases: [], type: 'project' }));
  return [...world.finalGraph.entities, ...removed.filter((r) => !world.finalGraph.entities.some((e) => e.id === r.id))];
}

/** Gold id for a name: exact name, else an alias unique among gold entities. */
export function goldIdFor(name, gold) {
  const n = norm(name);
  const exact = gold.find((g) => norm(g.name) === n);
  if (exact) return exact.id;
  const byAlias = gold.filter((g) => (g.aliases ?? []).some((a) => norm(a) === n));
  return byAlias.length === 1 ? byAlias[0].id : null;
}

/** predicted: [{id, name}]. Each gold entity matches at most one predicted entity. */
export function matchEntities(predicted, gold) {
  const map = new Map();
  const used = new Set();
  for (const p of predicted) {
    const g = goldIdFor(p.name, gold);
    if (g && !used.has(g)) { map.set(p.id, g); used.add(g); }
  }
  const tp = used.size;
  return { tp, fp: predicted.length - tp, fn: gold.length - tp, map };
}

/** Unordered entity-pair F1: predicted relations use predicted ids, mapped to gold ids via `map`. */
export function pairF1(predicted, goldRelations, map) {
  const key = (a, b) => [a, b].sort().join('|');
  const goldPairs = new Set(goldRelations.map((r) => key(r.source, r.target)));
  const predPairs = new Set();
  let unmatched = 0;
  for (const r of predicted) {
    const a = map.get(r.source);
    const b = map.get(r.target);
    if (a && b && a !== b) predPairs.add(key(a, b));
    else unmatched += 1;
  }
  const tp = [...predPairs].filter((k) => goldPairs.has(k)).length;
  return { tp, fp: predPairs.size - tp + unmatched, fn: goldPairs.size - tp };
}

/**
 * For each extracted entity that matches a gold entity, what admission did with it:
 * rejected (the turn's commit failed), persisted (new and stored), merged_correct
 * (folded into an entity that already was this gold entity), merged_wrong (stored
 * under an entity that is a different gold entity), dropped (committed but absent).
 * idFor(name) -> the entity id the merge gave this name (defaults to name lookup in `after`).
 */
export function admissionOutcomes({ patch, commit, before, after, gold, idFor }) {
  const out = [];
  const lookup = idFor ?? ((name) => Object.values(after.entities).find((e) => norm(e.name) === norm(name))?.id);
  for (const e of patch?.entities ?? []) {
    const g = goldIdFor(e.name, gold);
    if (!g) continue;
    let outcome;
    if (commit?.status !== 'committed') outcome = 'rejected';
    else {
      const storedId = lookup(e.name);
      const stored = storedId ? after.entities[storedId] : null;
      if (!stored) outcome = 'dropped';
      else {
        const storedGold = goldIdFor(stored.name, gold);
        if (storedGold !== g) outcome = 'merged_wrong';
        else outcome = before.entities[storedId] ? 'merged_correct' : 'persisted';
      }
    }
    out.push({ name: e.name, gold: g, outcome });
  }
  return out;
}

/** The memory-harness scenario shape for replayScenario. */
export function worldToScenario(world, written) {
  return {
    id: world.id,
    category: 'continuity',
    sessions: world.sessions.map((_, i) => ({ turns: written.turns.filter((t) => t.session === i + 1).map((t) => t.text) })),
    actions: world.sessions.flatMap((s, i) => s.actions.map((a) => ({ after_session: i + 1, kind: a.kind, name: a.name }))),
    probes: [],
  };
}

const LABEL_SYSTEM = 'You compare relationship labels from a memory graph. For each pair, the two labels connect the same two things (a person, place, organisation, project or event). Say whether they describe the same relationship. Different tenses or wording of one relationship are the same; different relationships (where someone lives vs where they grew up) are not.';
const LABEL_SCHEMA = {
  type: 'object',
  properties: { pairs: { type: 'array', items: { type: 'object', properties: { index: { type: 'integer' }, same: { type: 'boolean' } }, required: ['index', 'same'], additionalProperties: false } } },
  required: ['pairs'],
  additionalProperties: false,
};

/** pairs: [{gold, predicted}] labels. Claude on the plan decides equivalence; cached by the exact list. */
export async function typedMatches(runner, pairs, cache) {
  if (!pairs.length) return [];
  const prompt = pairs.map((p, i) => `${i}. gold: ${p.gold} | extracted: ${p.predicted}`).join('\n');
  const key = `labels:${prompt}`;
  let output = cache.get(key);
  if (!output) {
    ({ output } = await runner.run({ system: LABEL_SYSTEM, prompt, schema: LABEL_SCHEMA }));
    cache.set(key, output);
  }
  return pairs.map((_, i) => output.pairs.find((p) => p.index === i)?.same === true);
}
