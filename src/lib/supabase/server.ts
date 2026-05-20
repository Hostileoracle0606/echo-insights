import { createServerClient, type CookieOptions } from "@supabase/ssr";
import type { Database } from "./types";

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string;
const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string;

/**
 * Build a per-request Supabase client for SSR loaders. Cookies are
 * bridged via the provided `request` and `response` objects so the
 * session cookie set during sign-in is visible on the very next
 * server render.
 *
 * Usage inside a TanStack Start route loader:
 *   const supabase = getServerSupabase(request, response);
 *   const { data: { user } } = await supabase.auth.getUser();
 */
export function getServerSupabase(request: Request, response: Response) {
  const requestCookies = parseCookies(request.headers.get("cookie") ?? "");
  return createServerClient<Database>(SUPABASE_URL, SUPABASE_KEY, {
    cookies: {
      get(name: string) {
        return requestCookies[name];
      },
      set(name: string, value: string, options: CookieOptions) {
        response.headers.append("set-cookie", serializeCookie(name, value, options));
      },
      remove(name: string, options: CookieOptions) {
        response.headers.append(
          "set-cookie",
          serializeCookie(name, "", { ...options, maxAge: 0 }),
        );
      },
    },
  });
}

// ─── tiny cookie helpers (no extra deps) ──────────────────────────
function parseCookies(header: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const part of header.split(";")) {
    const trimmed = part.trim();
    if (!trimmed) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const name = trimmed.slice(0, eq).trim();
    const value = decodeURIComponent(trimmed.slice(eq + 1).trim());
    out[name] = value;
  }
  return out;
}

function serializeCookie(name: string, value: string, options: CookieOptions): string {
  const parts: string[] = [`${name}=${encodeURIComponent(value)}`];
  if (options.maxAge !== undefined) parts.push(`Max-Age=${options.maxAge}`);
  if (options.domain) parts.push(`Domain=${options.domain}`);
  if (options.path) parts.push(`Path=${options.path}`);
  if (options.expires) parts.push(`Expires=${options.expires.toUTCString()}`);
  if (options.httpOnly) parts.push("HttpOnly");
  if (options.secure) parts.push("Secure");
  if (options.sameSite) parts.push(`SameSite=${options.sameSite}`);
  return parts.join("; ");
}
