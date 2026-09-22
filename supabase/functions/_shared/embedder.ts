// Pluggable embedding provider. Prod uses the native gte-small model available
// only in the Supabase edge runtime; the stub runs anywhere (local tests/eval).
export interface Embedder {
  readonly modelId: string;
  embed(texts: string[]): Promise<number[][]>;
}

const DIM = 384;

/** Native gte-small (384-dim). `Supabase.ai` exists only in the deployed edge runtime. */
export class GteSmallEmbedder implements Embedder {
  readonly modelId = "gte-small@1";
  // deno-lint-ignore no-explicit-any
  #session = new (globalThis as any).Supabase.ai.Session("gte-small");
  async embed(texts: string[]): Promise<number[][]> {
    const out: number[][] = [];
    for (const t of texts) {
      out.push(await this.#session.run(t, { mean_pool: true, normalize: true }) as number[]);
    }
    return out;
  }
}

/** Deterministic hash-feature stub for local tests/eval (no Supabase.ai). */
export class StubEmbedder implements Embedder {
  readonly modelId = "stub@1";
  async embed(texts: string[]): Promise<number[][]> {
    return texts.map((t) => {
      const v = new Array<number>(DIM).fill(0);
      for (const tok of t.toLowerCase().split(/\s+/).filter(Boolean)) {
        let h = 2166136261;
        for (let i = 0; i < tok.length; i++) { h ^= tok.charCodeAt(i); h = Math.imul(h, 16777619); }
        v[Math.abs(h) % DIM] += 1;
      }
      const norm = Math.hypot(...v) || 1;
      return v.map((x) => x / norm);
    });
  }
}
