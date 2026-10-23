// Regenerates the golden output for the iPhone Markdown export
// (test/markdown_export_test.dart) by running the WEB exporter,
// src/lib/obsidian-export.ts, on the shared fixture state.
//
//   node scripts/markdown-export-fixtures.ts
//
// Needs Node >= 22.18 (built-in type stripping) and `npm install` for JSZip.
// The output is pinned so it is the same on every machine: the clock is
// frozen at FIXED_NOW, the time zone is UTC and the locale is en-US.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

process.env.TZ = "UTC";

const FIXED_NOW = Date.parse("2026-04-27T09:30:00.000Z");
const RealDate = Date;
class FixedDate extends RealDate {
  constructor(...args: unknown[]) {
    if (args.length === 0) super(FIXED_NOW);
    else super(...(args as [string]));
  }
  static now() {
    return FIXED_NOW;
  }
}
globalThis.Date = FixedDate as DateConstructor;
const toLocaleString = RealDate.prototype.toLocaleString;
const toLocaleDateString = RealDate.prototype.toLocaleDateString;
RealDate.prototype.toLocaleString = function (locales, options) {
  return toLocaleString.call(this, locales ?? "en-US", options);
};
RealDate.prototype.toLocaleDateString = function (locales, options) {
  return toLocaleDateString.call(this, locales ?? "en-US", options);
};

const { exportToObsidianZip } = await import("../src/lib/obsidian-export.ts");
const { default: JSZip } = await import("jszip");

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const fixtureDir = join(root, "test/fixtures/markdown_export");
const outDir = join(fixtureDir, "web");

const state = JSON.parse(readFileSync(join(fixtureDir, "state.json"), "utf8"));
const blob = await exportToObsidianZip(state);
const zip = await JSZip.loadAsync(await blob.arrayBuffer());

rmSync(outDir, { recursive: true, force: true });
const paths: string[] = [];
for (const file of Object.values(zip.files)) {
  if (file.dir) continue;
  paths.push(file.name);
  const target = join(outDir, file.name);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, await file.async("string"));
}
// Zip order is part of the contract: the Dart vault is an ordered map.
writeFileSync(join(fixtureDir, "web-paths.json"), `${JSON.stringify(paths, null, 2)}\n`);
console.log(paths.join("\n"));
