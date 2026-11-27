// The reranker model is too large to ship inside the function bundle, so it is
// stored as an artifact (private Storage bucket `ml-models`, keyed by its hash)
// and loaded on the first scored call. It is refused unless its sha256 matches
// the manifest pin (_shared/reranker/manifest.json).
export async function loadVerifiedModel({ sha256, download }: {
  sha256: string;
  download: (path: string) => Promise<Uint8Array>;
}): Promise<Uint8Array> {
  const bytes = await download(`reranker/${sha256}.onnx`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)));
  const hex = [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (hex !== sha256) throw new Error(`Reranker model sha256 mismatch (${hex.slice(0, 12)}…)`);
  return bytes;
}
