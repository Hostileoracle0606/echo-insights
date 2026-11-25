// Turns a world's statements and query intents into natural language with
// Claude (on the plan), then checks the language against the world. Output
// that fails a check is regenerated with the reasons, at most twice; after
// that the whole world is dropped. Nothing is ever patched by hand or code.
import { createHash } from 'node:crypto';

import { QUERIES_SCHEMA, QUERIES_SYSTEM, TURNS_SCHEMA, TURNS_SYSTEM, queriesPrompt, turnsPrompt } from './prompts.mjs';

// Disjoint question-style instructions per split (the "generation scenario"
// split): test questions are never phrased the way train/val ones are.
export const PHRASING_SETS = {
  train: [
    'Ask plainly and directly, like a quick check.',
    'Ask while thinking out loud, with a short lead-in about why you are wondering.',
    'Ask in a slightly tired, end-of-day tone.',
    'Ask as a follow-up to something you were just saying.',
    'Ask using a casual contraction-heavy style.',
    'Ask politely, as if you might have forgotten telling Lumen.',
  ],
  val: [
    'Ask briefly, in under ten words.',
    'Ask with a little uncertainty, as if you are not sure Lumen knows.',
    'Ask as if reminding yourself, starting with "wait".',
    'Ask while multitasking, a bit distracted.',
  ],
  test: [
    'Ask in a roundabout way, describing the thing instead of naming it where the intent allows.',
    'Ask as part of a longer thought, with one clause of context first.',
    'Ask in a warm, chatty tone, as if catching up with a friend.',
    'Ask indirectly, as a statement that invites Lumen to fill in the answer.',
    'Ask with a hesitant restart, like "so, um, what about...".',
    'Ask formally and precisely, as if checking a record.',
  ],
};

export class WorldDropped extends Error {
  constructor(worldId, errors) { super(`world ${worldId} dropped: ${errors.slice(0, 3).join('; ')}`); this.name = 'WorldDropped'; this.errors = errors; }
}

const norm = (s) => ` ${String(s).toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, ' ').trim()} `;
const mentions = (text, term) => norm(text).includes(norm(term));

/** Terms (entity names and stated values) with the first session they may appear in. */
function firstSessions(world) {
  const first = new Map();
  const note = (term, session) => { if (term && (!first.has(term) || first.get(term) > session)) first.set(term, session); };
  for (const s of world.sessions) {
    for (const f of s.facts) {
      for (const n of f.names) note(n, f.session);
      if (f.value) note(f.value, f.session);
    }
  }
  // A value that also appears earlier as something else (rare) is not a leak signal.
  return first;
}

const entityByName = (world, name) => world.finalGraph.entities.find((e) => e.name === name);

function sessionErrors(world, session, turns) {
  const errors = [];
  const facts = new Map(world.sessions[session - 1].facts.map((f) => [f.id, f]));
  const first = firstSessions(world);
  for (const t of turns) {
    for (const fid of t.factIds) {
      const f = facts.get(fid);
      if (!f) { errors.push(`turn claims fact ${fid}, which is not in session ${session}`); continue; }
      for (const name of f.names) {
        const e = entityByName(world, name);
        const ok = mentions(t.text, name) || (e?.type === 'person' && e.aliases.some((a) => mentions(t.text, a)));
        if (!ok) errors.push(`fact ${fid} needs "${name}" but the turn doesn't mention it`);
      }
    }
    for (const [term, s] of first) {
      if (s > session && mentions(t.text, term)) errors.push(`"${term}" first appears in session ${s}, later than session ${session}`);
    }
  }
  const claimed = turns.flatMap((t) => t.factIds);
  for (const fid of facts.keys()) {
    const n = claimed.filter((c) => c === fid).length;
    if (n === 0) errors.push(`fact ${fid} is not covered by any turn`);
    if (n > 1) errors.push(`fact ${fid} is claimed by ${n} turns`);
  }
  return errors;
}

/** turns: [{ session, text, factIds }] for the whole world. */
export function validateTurns(world, turns) {
  const errors = [];
  world.sessions.forEach((s, i) => {
    const mine = turns.filter((t) => t.session === i + 1);
    if (s.facts.length === 0 && mine.length === 0) return;
    errors.push(...sessionErrors(world, i + 1, mine));
  });
  return errors;
}

export function validateQueries(world, queries) {
  const errors = [];
  for (const q of world.queries) {
    const written = queries.filter((x) => x.id === q.id);
    if (written.length !== 1) { errors.push(`query ${q.id} written ${written.length} times`); continue; }
    const text = written[0].text;
    if (!text.trim()) errors.push(`query ${q.id} is empty`);
    for (const term of q.avoidTerms) if (mentions(text, term)) errors.push(`query ${q.id} uses avoided term "${term}"`);
  }
  return errors;
}

const key = (system, prompt, schema) => createHash('sha256').update(`${system}\n${prompt}\n${JSON.stringify(schema)}`).digest('hex');

async function cachedRun(runner, cache, req) {
  const k = key(req.system, req.prompt, req.schema);
  const hit = cache.get(k);
  if (hit) return hit;
  const { output } = await runner.run(req);
  cache.set(k, output);
  return output;
}

const styleFor = (world) => {
  const set = PHRASING_SETS[world.split];
  return set[world.seed % set.length];
};

/** Returns { turns: [{session, text, factIds}], queries: [{id, text}], style }; throws WorldDropped. */
export async function writeWorld({ world, runner, cache, maxRetries = 2 }) {
  const turns = [];
  for (let i = 0; i < world.sessions.length; i += 1) {
    const facts = world.sessions[i].facts;
    if (!facts.length) continue;
    let errors = [];
    let accepted = null;
    for (let attempt = 0; attempt <= maxRetries && !accepted; attempt += 1) {
      const out = await cachedRun(runner, cache, { system: TURNS_SYSTEM, prompt: turnsPrompt(i + 1, facts, errors, attempt), schema: TURNS_SCHEMA });
      const candidate = out.turns.map((t) => ({ session: i + 1, text: t.text, factIds: t.factIds }));
      errors = sessionErrors(world, i + 1, candidate);
      if (!errors.length) accepted = candidate;
    }
    if (!accepted) throw new WorldDropped(world.id, errors);
    turns.push(...accepted);
  }

  const style = styleFor(world);
  let errors = [];
  for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
    const out = await cachedRun(runner, cache, { system: QUERIES_SYSTEM, prompt: queriesPrompt(world.queries, style, errors, attempt), schema: QUERIES_SCHEMA });
    errors = validateQueries(world, out.queries);
    if (!errors.length) return { turns, queries: out.queries, style };
  }
  throw new WorldDropped(world.id, errors);
}
