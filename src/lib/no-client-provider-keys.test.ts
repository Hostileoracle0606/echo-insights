import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

import { describe, expect, it } from "vitest";

// Vite inlines every `import.meta.env.VITE_*` value into the client bundle.
// A provider credential read that way ships to every visitor, so client code
// must reach providers through server routes that hold the key instead.
const SRC = join(__dirname, "..");
const PROVIDER_SECRET = /import\.meta\.env\.(VITE_[A-Z0-9_]*(?:API_KEY|SECRET|TOKEN))\b/g;

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return sourceFiles(path);
    return /\.(ts|tsx)$/.test(name) && !/\.test\.tsx?$/.test(name) ? [path] : [];
  });
}

describe("client source", () => {
  it("never reads a provider credential from VITE_* env", () => {
    const offenders = sourceFiles(SRC).flatMap((file) =>
      [...readFileSync(file, "utf8").matchAll(PROVIDER_SECRET)].map(
        (match) => `${relative(SRC, file)}: ${match[1]}`,
      ),
    );
    expect(offenders).toEqual([]);
  });
});
