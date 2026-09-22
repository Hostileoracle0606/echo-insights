import { createBrowserClient } from "@supabase/ssr";
import type { Database } from "./types";

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

if (!SUPABASE_URL || !SUPABASE_KEY) {
  throw new Error("Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY in .env");
}

/**
 * Singleton browser client. Cookies are read/written through document.cookie
 * by @supabase/ssr's default browser adapter. Safe to import from any
 * "use client"-style component or hook.
 */
export const supabase = createBrowserClient<Database>(SUPABASE_URL, SUPABASE_KEY);
