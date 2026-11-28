// The memory reranker served inside this edge function: the pool-trained
// 2-layer MiniLM (int8 ONNX, _shared/reranker), behind the same MemoryReranker
// interface as the HTTP adapter. Trained and evaluated in ml/reranker on
// feat/reranker; the manifest pins the served file.
import { type MemoryReranker, withRerankDeadline } from "./memory-reranker.ts";

export function createEdgeMemoryReranker({ score, timeoutMs }: {
  score: (query: string, cards: string[]) => Promise<number[]>;
  timeoutMs: number;
}): MemoryReranker {
  return {
    rank: (query, documents, parentSignal) =>
      withRerankDeadline(parentSignal, timeoutMs, async () => {
        const scores = await score(query, documents.map(({ text }) => text));
        if (scores.length !== documents.length || !scores.every(Number.isFinite)) {
          throw new TypeError("Expected one finite score per candidate");
        }
        return new Map(documents.map(({ id }, index) => [id, scores[index]]));
      }),
  };
}
