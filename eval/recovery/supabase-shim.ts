// Stands in for src/lib/supabase/browser.ts under the recovery eval. The app
// modules read `supabase` at call time (an ES live binding), so a scenario can
// point them at a client built on its own fetch.
import type { SupabaseClient } from "@supabase/supabase-js";

export let supabase: SupabaseClient = new Proxy({} as SupabaseClient, {
  get() {
    throw new Error("recovery eval: useSupabase() was not called");
  },
});

export function useSupabase(client: SupabaseClient): void {
  supabase = client;
}
