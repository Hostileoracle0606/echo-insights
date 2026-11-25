/**
 * One production replay per test world (extraction Lambda in-process with real
 * Gemini, the app's merge, commit_notebook), reported per turn through the
 * replay hook. That single replay feeds the extraction and admission tracks
 * here, and its final snapshot feeds the end-to-end track.
 */
import { replayScenario, type TurnReport } from "../../memory/replay";
import { takeSnapshot } from "../../memory/snapshot.mjs";
import { withUser } from "../../memory/stack.mjs";
import { admissionOutcomes, goldEntities, goldIdFor, matchEntities, pairF1, typedMatches, worldToScenario } from "./match.mjs";

const norm = (s: string) => String(s ?? "").toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, " ").trim();

type Cache = { get: (k: string) => any; set: (k: string, v: any) => void };

export async function replayWorld({ record, stack, geminiKey, fetchImpl, runner, cache }: {
  record: { world: any; written: any };
  stack: any;
  geminiKey: string;
  fetchImpl: any;
  runner: { run: (req: any) => Promise<any> };
  cache: Cache;
}) {
  const { world, written } = record;
  const scenario = worldToScenario(world, written);
  const turns: TurnReport[] = [];
  const { value: result, leftover } = await withUser(stack, (user: { id: string; token: string }) => replayScenario({
    scenario: scenario as any,
    env: { supabaseUrl: stack.url, anonKey: stack.anonKey, user, geminiKey },
    fetchImpl,
    takeSnapshot: (notebookId: string) => takeSnapshot({ ...stack.admin, userId: user.id, notebookId }),
    onTurn: (t) => { turns.push(t); },
  }));

  const gold = goldEntities(world);
  // Extraction: everything the extractor said across turns, before admission.
  const byName = new Map<string, { id: string; name: string; descriptions: string[] }>();
  for (const t of turns) {
    for (const e of t.patch?.entities ?? []) {
      const k = norm(e.name);
      const cur = byName.get(k) ?? { id: k, name: e.name, descriptions: [] };
      if (e.description) cur.descriptions.push(e.description);
      byName.set(k, cur);
    }
  }
  const predicted = [...byName.values()];
  const entities = matchEntities(predicted, gold);
  const predictedRelations = turns.flatMap((t) => (t.patch?.relations ?? []).map((r) => ({ source: norm(r.source), label: r.label, target: norm(r.target) })));
  const goldRelations = world.finalGraph.relations;
  const pairs = pairF1(predictedRelations, goldRelations, entities.map);

  // Typed: for each gold relation whose pair was found, does an extracted label mean the same?
  const keyOf = (a: string, b: string) => [a, b].sort().join("|");
  const labelPairs: Array<{ gold: string; predicted: string; key: string }> = [];
  for (const g of goldRelations) {
    const k = keyOf(g.source, g.target);
    const p = predictedRelations.find((r) => {
      const a = entities.map.get(r.source);
      const b = entities.map.get(r.target);
      return a && b && keyOf(a, b) === k;
    });
    if (p) labelPairs.push({ gold: g.label, predicted: p.label, key: k });
  }
  const same = await typedMatches(runner, labelPairs.map(({ gold: g, predicted: p }) => ({ gold: g, predicted: p })), cache);
  const typedTp = same.filter(Boolean).length;
  const typed = { tp: typedTp, fp: pairs.tp + pairs.fp - typedTp, fn: goldRelations.length - typedTp };

  // Attributes: each gold attribute value mentioned in what the extractor said about that entity.
  let attrHit = 0;
  let attrOf = 0;
  for (const g of world.finalGraph.entities) {
    for (const value of Object.values(g.attributes ?? {}) as string[]) {
      attrOf += 1;
      const p = predicted.find((x) => entities.map.get(x.id) === g.id);
      if (p && p.descriptions.some((d) => norm(d).includes(norm(value)))) attrHit += 1;
    }
  }

  const admission = turns.flatMap((t) => admissionOutcomes({
    patch: t.patch, commit: t.commit, before: t.before, after: t.after, gold, idFor: undefined,
  }).map((o) => ({ ...o, turnId: t.turnId })));

  return {
    worldId: world.id,
    extraction: { entities: { tp: entities.tp, fp: entities.fp, fn: entities.fn }, pairs, typed, attributes: { hit: attrHit, of: attrOf },
      extractedNames: predicted.map((p) => p.name), matched: Object.fromEntries(entities.map) },
    admission,
    latency: turns.map((t) => ({ turnId: t.turnId, ...t.latencyMs })),
    lostTurns: result.meta.lostTurns,
    actions: result.meta.actions,
    providerCalls: result.meta.providerCalls,
    snapshot: result.snapshot,
    leftover,
    // For attribution: which gold entities the extractor produced and which were stored at the end.
    extractedGold: [...new Set(entities.map.values())],
    storedGold: [...new Set(Object.values((turns.at(-1)?.after ?? { entities: {} }).entities)
      .map((e: any) => goldIdFor(e.name, gold)).filter(Boolean))],
  };
}
