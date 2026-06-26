// Copies the graphloop retrieval subset into the edge function's _shared dir,
// rewriting for Deno: explicit .ts extensions on relative imports, and a stub
// for embed.ts (never called in lexical mode) so the `ai` dep is dropped.
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC = join(root, "src/lib/graphloop");
const FILES = ["types.ts", "noise.ts", "graph-ops.ts", "search-index.ts", "communities.ts", "retrieve.ts"];

// embed.ts is value-imported by retrieve.ts but never invoked in lexical mode.
// Stub it so the vendored copy carries no dependency on the `ai` package.
const EMBED_STUB = `// Generated stub — lexical-only retrieval never calls embedTexts.
import type { EmbeddingModel } from "./types.ts";
export async function embedTexts(_model: EmbeddingModel, _texts: string[]): Promise<number[][]> {
  throw new Error("embedTexts is stubbed in the edge function (lexical mode only)");
}
`;

// retrieve.ts imports EmbeddingModel from "ai"; repoint it at a local alias so
// the vendored copy needs no `ai` import. types.ts gains the alias (Step 2 note).
export function transform(file, body) {
  if (file === "embed.ts") return EMBED_STUB;
  let out = body.replace(/from "(\.[^"]+)"/g, (m, p) => (p.endsWith(".ts") ? m : `from "${p}.ts"`));
  if (file === "retrieve.ts") {
    out = out.replace(/import type \{ EmbeddingModel \} from "ai";/, `import type { EmbeddingModel } from "./types.ts";`);
  }
  return out;
}

export function syncInto(destDir) {
  rmSync(destDir, { recursive: true, force: true });
  mkdirSync(destDir, { recursive: true });
  for (const f of [...FILES, "embed.ts"]) {
    const body = f === "embed.ts" ? "" : readFileSync(join(SRC, f), "utf8");
    writeFileSync(join(destDir, f), transform(f, body));
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  syncInto(join(root, "supabase/functions/_shared/graphloop"));
  console.log("synced graphloop -> supabase/functions/_shared/graphloop");
}
