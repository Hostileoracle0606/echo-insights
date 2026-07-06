import type {
  CommunitySummary,
  Entity,
  GraphState,
  RankWeights,
  Relation,
  RetrievalOptions,
  RetrievalResult,
} from "./types";
import { DEFAULT_RANK_WEIGHTS } from "./types";
import { activeRelations, buildNeighbors, relationUncertainty, wordCount } from "./graph-ops";
import { normalizeName } from "./noise";
import { embedTexts } from "./embed";
import type { SearchIndex } from "./search-index";
import type { EmbeddingModel } from "ai";

export interface RetrieveDeps {
  index: SearchIndex;
  embedModel?: EmbeddingModel;
  communities?: CommunitySummary[];
  now?: number;
  /** Externally-computed semantic seeds (entity-id → relevance in [0,1]); unioned with lexical seeds. */
  extraSeeds?: Map<string, number>;
}

const MAX_COMMUNITY_SUMMARIES = 5;

const emptyResult = (): RetrievalResult => ({
  entities: [],
  relations: [],
  entries: [],
  seeds: [],
  context: "",
});

function resolveOptions(opts: RetrievalOptions | undefined, deps: RetrieveDeps) {
  const o = opts ?? {};
  const rawMode = o.mode ?? "auto";
  const mode: "lexical" | "hybrid" =
    rawMode === "auto" ? (deps.embedModel ? "hybrid" : "lexical") : rawMode;
  return {
    hops: o.hops ?? 2,
    maxEntities: o.maxEntities ?? 24,
    maxRelations: o.maxRelations ?? 48,
    tier: o.tier ?? "auto",
    mode,
    weights: { ...DEFAULT_RANK_WEIGHTS, ...(o.weights ?? {}) } as RankWeights,
  };
}

export async function retrieve(
  state: GraphState,
  query: string,
  opts: RetrievalOptions | undefined,
  deps: RetrieveDeps,
): Promise<RetrievalResult> {
  const q = query.trim();
  if (!q) return emptyResult();
  const o = resolveOptions(opts, deps);
  const now = deps.now ?? Date.now();

  // ---- 1. seed selection ----
  let queryVector: number[] | undefined;
  if (o.mode === "hybrid" && deps.embedModel) {
    try {
      queryVector = (await embedTexts(deps.embedModel, [q]))[0];
    } catch {
      queryVector = undefined;
    } // graceful fallback to BM25
  }
  const hits = await deps.index.search(q, queryVector, o.maxEntities * 2);
  const seedScore = new Map<string, number>();
  for (const h of hits) seedScore.set(h.id, Math.max(seedScore.get(h.id) ?? 0, h.score));

  // always include exact normalized-name matches
  const nq = normalizeName(q);
  for (const e of Object.values(state.entities)) {
    const nn = normalizeName(e.name);
    if (nn.length >= 2 && nq.includes(nn))
      seedScore.set(e.id, Math.max(seedScore.get(e.id) ?? 0, 1));
  }

  // externally-supplied semantic seeds (hybrid) — union by max score
  if (deps.extraSeeds) {
    for (const [id, score] of deps.extraSeeds) {
      if (state.entities[id]) seedScore.set(id, Math.max(seedScore.get(id) ?? 0, score));
    }
  }

  const seeds = [...seedScore.keys()].filter((id) => state.entities[id]);

  // normalize seed scores to [0,1]
  const maxSeed = Math.max(1, ...seeds.map((id) => seedScore.get(id) ?? 0));
  const seedRel = new Map(seeds.map((id) => [id, (seedScore.get(id) ?? 0) / maxSeed]));

  if (seeds.length === 0 || o.tier === "global") {
    return globalResult(deps.communities ?? []);
  }

  // ---- 2. expansion (BFS k-hop over active relations) ----
  const active = activeRelations(state);
  const neighbors = buildNeighbors(active);
  const hop = new Map<string, number>();
  for (const s of seeds) hop.set(s, 0);
  let frontier = [...seeds];
  for (let d = 1; d <= o.hops; d++) {
    const next: string[] = [];
    for (const id of frontier) {
      for (const nb of neighbors.get(id) ?? []) {
        if (!hop.has(nb)) {
          hop.set(nb, d);
          next.push(nb);
        }
      }
    }
    frontier = next;
  }

  // ---- 3 + 4. provenance prep + ranking ----
  const uncertainty = relationUncertainty(state);
  const relByEntity = new Map<string, Relation[]>();
  for (const r of active) {
    if (!relByEntity.has(r.source)) relByEntity.set(r.source, []);
    if (!relByEntity.has(r.target)) relByEntity.set(r.target, []);
    relByEntity.get(r.source)!.push(r);
    relByEntity.get(r.target)!.push(r);
  }
  const maxMentions = Math.max(1, ...Object.values(state.entities).map((e) => e.mentions));

  const scored = [...hop.keys()]
    .map((id) => {
      const e = state.entities[id];
      if (!e) return null;
      const d = hop.get(id) ?? 0;
      const relevance = (d === 0 ? (seedRel.get(id) ?? 1) : 0.5) * Math.pow(0.6, d);
      const ageDays = Math.max(0, (now - Date.parse(e.lastSeen)) / 86_400_000);
      const recency = Math.exp(-ageDays / 30);
      const importance = Math.log(e.mentions + 1) / Math.log(maxMentions + 1);
      const incident = relByEntity.get(id) ?? [];
      const confidence = incident.length
        ? incident.reduce((acc, r) => acc + (1 - (uncertainty.get(r.id) ?? 0) / 3), 0) /
          incident.length
        : Math.min(1, wordCount(e.description) / 30);
      const total =
        o.weights.relevance * relevance +
        o.weights.recency * recency +
        o.weights.importance * importance +
        o.weights.confidence * confidence;
      return { id, e, total };
    })
    .filter((x): x is { id: string; e: Entity; total: number } => x !== null)
    .sort((a, b) => b.total - a.total);

  // ---- 5. budget (keep connectivity) ----
  const keptEntities = scored.slice(0, o.maxEntities).map((s) => s.e);
  const keptIds = new Set(keptEntities.map((e) => e.id));
  const keptRelations = active
    .filter((r) => keptIds.has(r.source) && keptIds.has(r.target))
    .slice(0, o.maxRelations);

  // ---- provenance entries ----
  const relIds = new Set(keptRelations.map((r) => r.id));
  const entries = state.entries.filter(
    (en) =>
      en.entityIds.some((id) => keptIds.has(id)) || en.relationIds.some((id) => relIds.has(id)),
  );

  // ---- 6. pack ----
  const context = packContext(keptEntities, keptRelations, entries);
  return { entities: keptEntities, relations: keptRelations, entries, seeds, context };
}

function globalResult(communities: CommunitySummary[]): RetrievalResult {
  if (communities.length === 0) return emptyResult();
  const top = communities.slice(0, MAX_COMMUNITY_SUMMARIES);
  const lines = ["## Relevant areas of memory"];
  for (const c of top) lines.push(`- ${c.label} (${c.size} entities): ${c.topEntities.join(", ")}`);
  return {
    entities: [],
    relations: [],
    entries: [],
    seeds: [],
    communities: top,
    context: lines.join("\n"),
  };
}

function packContext(
  entities: Entity[],
  relations: Relation[],
  entries: GraphState["entries"],
): string {
  if (entities.length === 0) return "";
  const byId = new Map(entities.map((e) => [e.id, e]));
  const out: string[] = ["## Entities"];
  for (const e of entities) {
    const desc = e.description ? `: ${e.description}` : "";
    out.push(`- ${e.name} (${e.type})${desc} [mentions: ${e.mentions}]`);
  }
  if (relations.length) {
    out.push("## Relations");
    for (const r of relations) {
      const s = byId.get(r.source)?.name ?? r.source;
      const t = byId.get(r.target)?.name ?? r.target;
      out.push(`- ${s} --${r.label}--> ${t}`);
    }
  }
  if (entries.length) {
    out.push("## Sources");
    for (const en of entries.slice(0, 12)) out.push(`- "${en.text}"`);
  }
  return out.join("\n");
}
