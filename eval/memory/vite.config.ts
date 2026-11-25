// Vite config for the memory eval (vite-node runner and its vitest tests):
// the repo's @ alias, and the browser Supabase client replaced by a stub. The
// eval talks to the local stack itself; the app's browser client would throw
// at import without VITE_* env and is never used here.
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import tsconfigPaths from "vite-tsconfig-paths";

const root = fileURLToPath(new URL("../..", import.meta.url));

export default defineConfig({
  root,
  plugins: [tsconfigPaths({ root })],
  resolve: {
    alias: [
      {
        find: "@/lib/supabase/browser",
        replacement: fileURLToPath(new URL("./no-browser-client.ts", import.meta.url)),
      },
      // tsconfig paths only cover files the tsconfig includes (src/**), not eval/.
      { find: /^@\//, replacement: `${root}src/` },
    ],
  },
  test: {
    environment: "node",
    include: ["eval/memory/**/*.test.ts"],
  },
});
