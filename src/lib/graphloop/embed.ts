import { embedMany, type EmbeddingModel } from "ai";

/** Embed an array of texts via the AI SDK. Returns one vector per input. */
export async function embedTexts(model: EmbeddingModel, texts: string[]): Promise<number[][]> {
  if (texts.length === 0) return [];
  const { embeddings } = await embedMany({ model, values: texts });
  return embeddings;
}
