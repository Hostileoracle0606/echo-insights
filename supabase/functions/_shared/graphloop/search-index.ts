/* eslint-disable @typescript-eslint/no-explicit-any */
import { create, removeMultiple, search, upsertMultiple } from "@orama/orama";
import type { Entity } from "./types.ts";

export interface SearchHit {
  id: string;
  score: number;
}

const contentHash = (e: Entity): string => `${e.lastSeen}|${e.name}|${e.description ?? ""}`;

const docFor = (e: Entity, vec?: number[]) => ({
  id: e.id,
  name: e.name,
  description: e.description ?? "",
  ...(vec ? { embedding: vec } : {}),
});

/**
 * Orama-backed index over entities. BM25 by default; hybrid when vectors are
 * supplied. The Orama db is created lazily on first sync so the vector field
 * dimension can be derived from the first embedding.
 */
export class SearchIndex {
  private db: Awaited<ReturnType<typeof create>> | null = null;
  private hashes = new Map<string, string>();
  private vectorDim: number | null = null;

  private async ensureDb(dim: number | null) {
    if (this.db && this.vectorDim === dim) return;
    this.vectorDim = dim;
    this.db = await create({
      schema: {
        name: "string",
        description: "string",
        ...(dim ? { embedding: `vector[${dim}]` as const } : {}),
      },
    });
    this.hashes.clear(); // schema changed → reindex everything next sync
  }

  /** Sync entities into the index. Returns how many docs were (re)indexed. */
  async sync(entities: Entity[], vectors?: Map<string, number[]>): Promise<{ indexed: number }> {
    const dim =
      vectors && vectors.size > 0
        ? (vectors.values().next().value?.length ?? null)
        : (this.vectorDim ?? null);
    await this.ensureDb(dim);

    const present = new Set(entities.map((e) => e.id));

    const pendingHashes = new Map<string, string>();
    const changed: Entity[] = [];
    for (const e of entities) {
      const h = `${contentHash(e)}|${vectors?.get(e.id) ? "v" : "n"}`;
      if (this.hashes.get(e.id) !== h) {
        changed.push(e);
        pendingHashes.set(e.id, h);
      }
    }
    const removed = [...this.hashes.keys()].filter((id) => !present.has(id));

    if (removed.length) {
      await removeMultiple(this.db!, removed);
      for (const id of removed) this.hashes.delete(id);
    }
    if (changed.length) {
      await upsertMultiple(
        this.db!,
        changed.map((e) => docFor(e, vectors?.get(e.id))),
      );
      for (const [id, h] of pendingHashes) this.hashes.set(id, h);
    }
    return { indexed: changed.length };
  }

  /** BM25 (and vector, if queryVector given) search. Returns ranked hits. */
  async search(
    term: string,
    queryVector: number[] | undefined,
    limit: number,
  ): Promise<SearchHit[]> {
    if (!this.db) return [];
    const params: Record<string, unknown> =
      queryVector && this.vectorDim
        ? {
            term,
            mode: "hybrid",
            vector: { value: queryVector, property: "embedding" },
            similarity: 0.0,
            limit,
          }
        : { term, properties: ["name", "description"], limit };
    const res: any = await search(this.db, params as any);
    return (res?.hits ?? []).map((h: any) => ({ id: h.id as string, score: h.score as number }));
  }
}
