// vite-node config for the recovery eval: the app's `@/` paths, with the
// browser Supabase singleton swapped for one the scenario controls (its fetch
// is the fault-injecting one). Everything else is the app's own code.
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));

export default defineConfig({
  resolve: {
    alias: [
      { find: /^@\/lib\/supabase\/browser$/, replacement: here("./supabase-shim.ts") },
      { find: /^@\//, replacement: here("../../src/") },
    ],
  },
});
