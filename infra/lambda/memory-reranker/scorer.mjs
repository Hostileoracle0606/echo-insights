// The pool-trained memory reranker (2-layer MiniLM cross-encoder, int8 ONNX) on
// native onnxruntime. The same weights and tokenizer as the edge build
// (supabase/functions/_shared/reranker); build.mjs bundles this file with that
// WordPiece source, so the two can't drift. It runs here because an edge worker
// is retired after about a second of CPU, and loading the model costs about half.
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

import * as ort from "onnxruntime-node";

import { WordPiece } from "../../../supabase/functions/_shared/reranker/wordpiece.ts";

/**
 * Loads the model (refused unless its sha256 matches the pin) and returns
 * `score(query, cards) → logits`, one per card, in order.
 * One pair per run, as in the evaluator: dynamic int8 quantisation picks
 * activation scales per run, so batching would make a card's score depend on
 * its neighbours.
 */
export async function loadScorer({ modelPath, vocabPath, sha256, maxLength }) {
  const [bytes, vocab] = await Promise.all([readFile(modelPath), readFile(vocabPath, "utf8")]);
  const got = createHash("sha256").update(bytes).digest("hex");
  if (got !== sha256) throw new Error("Reranker model does not match its pin");
  const session = await ort.InferenceSession.create(bytes, {
    intraOpNumThreads: 1,
    interOpNumThreads: 1,
    graphOptimizationLevel: "all",
  });
  const tokenizer = WordPiece.fromVocab(vocab);
  const tensor = (values) => new ort.Tensor("int64", BigInt64Array.from(values, BigInt), [1, values.length]);

  return async function score(query, cards) {
    const logits = [];
    for (const card of cards) {
      // The query is never cut, only the card (training used truncation="only_second").
      const { inputIds, tokenTypeIds } = tokenizer.encodePair(query, card, maxLength);
      const out = await session.run({
        input_ids: tensor(inputIds),
        attention_mask: tensor(inputIds.map(() => 1)),
        token_type_ids: tensor(tokenTypeIds),
      });
      logits.push(Number(out.logits.data[0]));
    }
    return logits;
  };
}
