// Seeded world generator: the ground truth of each benchmark history.
//
// A world is a user's small social graph and how it changes over 3-5
// sessions. Everything a label depends on (who exists, what changed when,
// what each question should retrieve, the answer) is decided here, in code.
// Claude only turns `statement`s into speech and `intent`s into questions
// (write.mjs), so labels can't drift from the text by construction.
import { rawPool } from './names.mjs';
import { FAMILY_NAMES } from './schema.mjs';

export const FAMILIES = FAMILY_NAMES;

const ROLES = ['nurse', 'teacher', 'carpenter', 'pharmacist', 'data analyst', 'paramedic', 'librarian', 'architect', 'chef', 'accountant', 'physiotherapist', 'sound engineer'];
const BONDS = ['friend', 'sister', 'brother', 'cousin', 'neighbour', 'old classmate', 'coworker', 'climbing partner'];

// mulberry32: small, fast, and identical on every platform.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const SPLIT_SALT = { train: 0x1000, val: 0x2000, test: 0x3000 };

const an = (word) => (/^[aeiou]/i.test(word) ? `an ${word}` : `a ${word}`);
const slug = (s) => s.toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

export function makeWorld({ seed, split, families }) {
  const rand = rng((seed * 2654435761) ^ SPLIT_SALT[split]);
  const int = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));
  const pool = rawPool(split);
  const bags = Object.fromEntries(Object.entries(pool).map(([k, v]) => [k, [...v]]));
  const take = (kind) => {
    const bag = bags[kind];
    if (!bag.length) throw new Error(`world ${seed}: ${kind} pool exhausted`);
    return bag.splice(Math.floor(rand() * bag.length), 1)[0];
  };
  const choose = (arr) => arr[Math.floor(rand() * arr.length)];

  const id = `${split}-${String(seed).padStart(4, '0')}`;
  const sessionCount = int(3, 5);
  const sessions = Array.from({ length: sessionCount }, () => ({ facts: [], actions: [] }));
  const entities = new Map();
  const relations = [];
  const removed = [];
  const queries = [];
  let factN = 0;
  const later = (after) => int(Math.min(after + 1, sessionCount), sessionCount);

  const addEntity = ({ name, nameParts, type, aliases = [], attributes = {} }) => {
    let eid = slug(name);
    while (entities.has(eid)) eid = `${eid}-2`;
    const e = { id: eid, name, nameParts, aliases, type, attributes: { ...attributes } };
    entities.set(eid, e);
    return e;
  };
  const person = ({ first = take('first'), bond = choose(BONDS), role = choose(ROLES) } = {}) => {
    const last = take('last');
    return addEntity({ name: `${first} ${last}`, nameParts: [first, last], type: 'person', aliases: [first], attributes: { bond, role } });
  };
  const town = () => { const t = take('town'); return addEntity({ name: t, nameParts: [t], type: 'place' }); };
  const org = () => { const o = take('org'); const s = take('orgSuffix'); return addEntity({ name: `${o} ${s}`, nameParts: [o, s], type: 'organization' }); };
  const project = () => { const p = take('project'); return addEntity({ name: p, nameParts: [p], type: 'project' }); };

  const fact = (session, f) => {
    const full = { id: `${id}-f${++factN}`, session, ...f };
    sessions[session - 1].facts.push(full);
    return full;
  };
  const introduce = (session, e, statement) => fact(session, { kind: 'introduce', subject: e.id, predicate: 'is', statement, names: [e.name] });
  const relate = (session, src, label, dst, statement, supersedes) => {
    relations.push({ source: src.id, label, target: dst.id, supersededInSession: null });
    return fact(session, { kind: 'relation', subject: src.id, predicate: label, object: dst.id, statement, names: [src.name, dst.name], ...(supersedes ? { supersedes } : {}) });
  };
  const supersede = (src, label, dst, session) => {
    const r = relations.find((x) => x.source === src.id && x.label === label && x.target === dst.id && x.supersededInSession == null);
    r.supersededInSession = session;
  };
  const query = (family, variant, intent, gold, answer, extra = {}) => {
    queries.push({ id: `${id}-q${queries.length + 1}`, family, template: `${family}.${variant}`, intent, gold, answer,
      answerable: gold.length > 0, distractors: [], avoidTerms: [], ...extra });
  };

  // Base cast: two people the user knows, met in session 1.
  const base = [person(), person()];
  for (const p of base) {
    introduce(1, p, `${p.name} is the user's ${p.attributes.bond}, who works as ${an(p.attributes.role)}.`);
  }

  const chosen = families ?? pickFamilies(rand);
  for (const family of chosen) {
    if (family === 'temporal_change') {
      const p = choose(base);
      const [a, b] = [town(), town()];
      const s1 = int(1, sessionCount - 1);
      const f1 = relate(s1, p, 'lives_in', a, `${p.name} lives in ${a.name}.`);
      const s2 = later(s1);
      supersede(p, 'lives_in', a, s2);
      relate(s2, p, 'lives_in', b, `${p.name} has just moved from ${a.name} to ${b.name}.`, f1.id);
      query(family, 'current', `Ask where ${p.aliases[0]} lives now.`,
        [{ entityId: b.id, relevance: 2 }, { entityId: p.id, relevance: 1 }], b.name);
      query(family, 'previous', `Ask where ${p.aliases[0]} used to live before moving.`,
        [{ entityId: a.id, relevance: 2 }, { entityId: p.id, relevance: 1 }], a.name);
    } else if (family === 'ambiguity') {
      const first = take('first');
      const workPal = person({ first, bond: 'coworker' });
      const climbPal = person({ first, bond: 'climbing partner' });
      const o = org();
      const s1 = int(1, sessionCount);
      introduce(s1, workPal, `${workPal.name} is a coworker of the user.`);
      relate(s1, workPal, 'works_at', o, `${workPal.name} works with the user at ${o.name}.`);
      const s2 = int(1, sessionCount);
      introduce(s2, climbPal, `${climbPal.name} is the user's climbing partner.`);
      query(family, 'by_context', `Ask something about ${first} from work, using only the first name "${first}" and a work context (no surname).`,
        [{ entityId: workPal.id, relevance: 2 }, { entityId: o.id, relevance: 1 }], workPal.name,
        { distractors: [climbPal.id] });
    } else if (family === 'multi_hop') {
      const p = choose(base);
      const o = org();
      const t = town();
      const s1 = int(1, sessionCount);
      relate(s1, p, 'works_at', o, `${p.name} works at ${o.name}.`);
      const s2 = int(1, sessionCount);
      relate(s2, o, 'located_in', t, `${o.name} is based in ${t.name}.`);
      query(family, 'workplace_town', `Ask which town ${p.aliases[0]}'s workplace is in, without naming the workplace or the town.`,
        [{ entityId: t.id, relevance: 2 }, { entityId: o.id, relevance: 1 }, { entityId: p.id, relevance: 1 }], t.name,
        { avoidTerms: [o.name, t.name] });
    } else if (family === 'contradiction') {
      const p = choose(base);
      const oldRole = p.attributes.role;
      const newRole = choose(ROLES.filter((r) => r !== oldRole));
      const s2 = later(1);
      p.attributes.role = newRole;
      fact(s2, { kind: 'attribute', subject: p.id, predicate: 'role', value: newRole,
        statement: `Correction: ${p.name} is actually ${an(newRole)}, not ${an(oldRole)}; the user had it wrong before.`, names: [p.name] });
      query(family, 'current_role', `Ask what ${p.aliases[0]} does for work.`, [{ entityId: p.id, relevance: 2 }], newRole,
        { avoidTerms: [newRole] });
    } else if (family === 'paraphrase') {
      const p = choose(base);
      const j = project();
      const s1 = int(1, sessionCount);
      introduce(s1, j, `The user is working on ${an(j.name)}.`);
      relate(s1, p, 'helps_with', j, `${p.name} is helping the user with the ${j.name}.`);
      query(family, 'indirect', `Ask how the thing the user is working on with their ${p.attributes.bond} is going, without naming the project or the person.`,
        [{ entityId: j.id, relevance: 2 }, { entityId: p.id, relevance: 1 }], j.name, { avoidTerms: [j.name, p.name, p.aliases[0]] });
    } else if (family === 'distractor') {
      const [nameA, nameB] = bags.similarTowns.splice(Math.floor(rand() * bags.similarTowns.length), 1)[0];
      const a = addEntity({ name: nameA, nameParts: [nameA], type: 'place' });
      const b = addEntity({ name: nameB, nameParts: [nameB], type: 'place' });
      const [p1, p2] = base;
      const s1 = int(1, sessionCount);
      relate(s1, p1, 'grew_up_in', a, `${p1.name} grew up in ${a.name}.`);
      const s2 = int(1, sessionCount);
      relate(s2, p2, 'grew_up_in', b, `${p2.name} grew up in ${b.name}.`);
      query(family, 'similar_place', `Ask where ${p1.aliases[0]} grew up.`, [{ entityId: a.id, relevance: 2 }, { entityId: p1.id, relevance: 1 }], a.name,
        { distractors: [b.id] });
    } else if (family === 'unanswerable') {
      if (rand() < 0.5) {
        const p = choose(base);
        query(family, 'never_said', `Ask what ${p.aliases[0]}'s favourite food is (the user never said).`, [], 'unknown');
      } else {
        const j = project();
        const s1 = int(1, sessionCount - 1);
        introduce(s1, j, `The user started ${an(j.name)}.`);
        const s2 = later(s1);
        sessions[s2 - 1].actions.push({ kind: 'remove', entityId: j.id, name: j.name });
        removed.push(j.id);
        entities.delete(j.id);
        query(family, 'removed', `Ask how the ${j.name} is going (the user asked Lumen to remove it).`, [], 'unknown', { avoidTerms: [] });
      }
    }
  }

  // Every session says something: fill gaps with a small event.
  sessions.forEach((s, i) => {
    if (s.facts.length + s.actions.length > 0) return;
    const p = choose(base);
    const ev = take('event');
    const e = addEntity({ name: ev, nameParts: [ev], type: 'event' });
    relate(i + 1, p, 'went_to', e, `The user went to ${an(ev)} with ${p.name}.`);
  });

  return {
    id, split, synthetic: true, seed, families: chosen, sessions,
    finalGraph: {
      entities: [...entities.values()],
      relations: relations.filter((r) => entities.has(r.source) && entities.has(r.target)),
      removed,
    },
    queries,
  };
}

// 2-3 distinct families per world.
function pickFamilies(rand) {
  const bag = [...FAMILIES];
  const n = 2 + Math.floor(rand() * 2);
  const out = [];
  for (let i = 0; i < n; i += 1) out.push(bag.splice(Math.floor(rand() * bag.length), 1)[0]);
  return out;
}
