// CI guard: regenerates the vendored copy into a temp dir and fails if it
// differs from the committed supabase/functions/_shared/graphloop. Run this
// whenever src/lib/graphloop changes.
import { readdirSync, readFileSync, mkdtempSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { syncInto } from "./sync-graphloop.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const committed = join(root, "supabase/functions/_shared/graphloop");
const temp = mkdtempSync(join(tmpdir(), "graphloop-"));
syncInto(temp);

let drift = false;
for (const f of readdirSync(temp)) {
  const a = readFileSync(join(temp, f), "utf8");
  const b = readFileSync(join(committed, f), "utf8");
  if (a !== b) { drift = true; console.error(`DRIFT: ${f}`); }
}
if (drift) { console.error("Run: node scripts/sync-graphloop.mjs && commit"); process.exit(1); }
console.log("graphloop vendored copy is in sync");
