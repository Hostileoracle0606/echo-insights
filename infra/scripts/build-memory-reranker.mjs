// Builds the memory reranker's Lambda package into <outDir>:
//
//   node scripts/build-memory-reranker.mjs <outDir> [linux-arm64|darwin-arm64|...]
//
// - index.mjs: this directory's handler bundled with the edge build's WordPiece
//   tokenizer (one source, no drift); the AWS SDK stays external (in the runtime).
// - model.int8.onnx + vocab.txt from supabase/functions/_shared/reranker, refused
//   unless the model matches the manifest's sha256 (ml/reranker/deploy/fetch_model.sh
//   fetches it).
// - node_modules with onnxruntime-node pruned to the target platform's binary.
// Also used by the stack's local bundling (lib/memory-reranker-stack.ts).
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const here = join(dirname(fileURLToPath(import.meta.url)), "..", "lambda", "memory-reranker");
const shared = join(here, "..", "..", "..", "supabase", "functions", "_shared", "reranker");

export async function buildPackage(outDir, target = "linux-arm64") {
  const [os, arch] = target.split("-");
  const manifest = JSON.parse(readFileSync(join(shared, "manifest.json"), "utf8"));
  const modelPath = join(shared, "model.int8.onnx");
  if (!existsSync(modelPath)) throw new Error("No model: run ml/reranker/deploy/fetch_model.sh first");
  const got = createHash("sha256").update(readFileSync(modelPath)).digest("hex");
  if (got !== manifest.sha256) throw new Error(`Model sha256 ${got} does not match the manifest`);

  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  await build({
    entryPoints: [join(here, "index.mjs")],
    outfile: join(outDir, "index.mjs"),
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node22",
    external: ["onnxruntime-node", "@aws-sdk/*"],
    logLevel: "warning",
  });
  writeFileSync(join(outDir, "package.json"), '{"type":"module"}\n');
  cpSync(modelPath, join(outDir, "model.int8.onnx"));
  cpSync(join(shared, "vocab.txt"), join(outDir, "vocab.txt"));
  // onnxruntime-node needs only onnxruntime-common at runtime (adm-zip and
  // global-agent are for its install script, which is not run).
  for (const name of ["onnxruntime-node", "onnxruntime-common"]) {
    cpSync(join(here, "node_modules", name), join(outDir, "node_modules", name), { recursive: true });
  }
  const bin = join(outDir, "node_modules", "onnxruntime-node", "bin", "napi-v6");
  for (const platform of readdirSync(bin)) {
    for (const cpu of readdirSync(join(bin, platform))) {
      if (platform !== os || cpu !== arch) rmSync(join(bin, platform, cpu), { recursive: true });
    }
    if (!readdirSync(join(bin, platform)).length) rmSync(join(bin, platform), { recursive: true });
  }
  if (!existsSync(join(bin, os, arch))) throw new Error(`onnxruntime-node has no ${target} binary`);
  return outDir;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [outDir, target] = process.argv.slice(2);
  if (!outDir) throw new Error("usage: build-memory-reranker.mjs <outDir> [os-arch]");
  await buildPackage(outDir, target);
  console.log(`memory-reranker: built ${target ?? "linux-arm64"} package in ${outDir}`);
}
