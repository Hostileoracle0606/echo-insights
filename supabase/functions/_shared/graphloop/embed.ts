// Generated stub — lexical-only retrieval never calls embedTexts.
import type { EmbeddingModel } from "./types.ts";
export async function embedTexts(_model: EmbeddingModel, _texts: string[]): Promise<number[][]> {
  throw new Error("embedTexts is stubbed in the edge function (lexical mode only)");
}
