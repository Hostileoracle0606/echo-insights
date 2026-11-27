// The memory reranker in the edge runtime: the pool-trained MiniLM-L6
// cross-encoder (int8 ONNX, onnxruntime-web WASM) scores every candidate card
// against the live tool's query in one batched run. Trained and evaluated in
// ml/reranker (RESULTS.md); manifest.json pins the weights' hash.
import * as ort from "npm:onnxruntime-web@1.22.0";

import { WordPiece } from "./wordpiece.ts";

export type Reranker = (query: string, documents: string[]) => Promise<number[]>;

export function createReranker(opts: {
  model: () => Promise<Uint8Array>;
  vocab: () => Promise<string>;
  maxLength: number;
  timeoutMs: number;
  /**
   * Pairs per run (default 1). Dynamic int8 quantisation picks activation scales per
   * run, so batching makes a card's score depend on its neighbours (top-3 changed on
   * 6 of 108 val pools). One pair per run is stable, unpadded, and what the
   * evaluator scores (ml/reranker/lumen_reranker/score.py).
   */
  batchSize?: number;
}): Reranker {
  const batchSize = opts.batchSize ?? 1;
  // One session per edge worker, loaded on first use; a failed load is retried next call.
  let ready: Promise<{ session: ort.InferenceSession; tokenizer: WordPiece }> | null = null;
  const load = () => {
    ready ??= (async () => {
      ort.env.wasm.numThreads = 1;
      const [bytes, vocab] = await Promise.all([opts.model(), opts.vocab()]);
      return {
        session: await ort.InferenceSession.create(bytes, { executionProviders: ["wasm"] }),
        tokenizer: WordPiece.fromVocab(vocab),
      };
    })().catch((error) => {
      ready = null;
      throw error;
    });
    return ready;
  };

  const score = async (query: string, documents: string[]): Promise<number[]> => {
    const { session, tokenizer } = await load();
    // The query is never cut, only the card (as in training: truncation="only_second").
    const pairs = documents.map((doc, index) => ({ index, ...tokenizer.encodePair(query, doc, opts.maxLength) }))
      .sort((a, b) => a.inputIds.length - b.inputIds.length);
    const logits = new Array<number>(documents.length);
    for (let start = 0; start < pairs.length; start += batchSize) {
      const batch = pairs.slice(start, start + batchSize);
      const width = batch[batch.length - 1].inputIds.length;
      const flat = (pick: (p: (typeof batch)[number], i: number) => number) =>
        BigInt64Array.from(batch.flatMap((p) => Array.from({ length: width }, (_, i) => BigInt(pick(p, i)))));
      const shape = [batch.length, width];
      const out = await session.run({
        input_ids: new ort.Tensor("int64", flat((p, i) => p.inputIds[i] ?? 0), shape),
        attention_mask: new ort.Tensor("int64", flat((p, i) => (i < p.inputIds.length ? 1 : 0)), shape),
        token_type_ids: new ort.Tensor("int64", flat((p, i) => p.tokenTypeIds[i] ?? 0), shape),
      });
      (out.logits.data as Float32Array).forEach((value, k) => { logits[batch[k].index] = Number(value); });
    }
    return logits;
  };

  return (query, documents) => {
    if (!documents.length) return Promise.resolve([]);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("reranker timed out")), opts.timeoutMs);
    });
    return Promise.race([score(query, documents), timeout]).finally(() => clearTimeout(timer));
  };
}
