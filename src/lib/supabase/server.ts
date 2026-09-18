import { createServerClient } from "@supabase/ssr";
import type { Database } from "./types";

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

if (!SUPABASE_URL || !SUPABASE_KEY) {
  throw new Error("Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY in .env");
}

/**
 * Build a per-request Supabase client for SSR loaders. Cookies are
 * bridged via the provided `request` and `response` objects so the
 * session cookie set during sign-in is visible on the very next
 * server render.
 *
 * Uses the @supabase/ssr 0.10+ getAll/setAll cookie interface — the
 * deprecated get/set/remove three-method API silently fails for
 * sessions chunked across more than 5 cookies (long JWTs, multiple
 * factors), causing random logouts.
 *
 * Usage inside a TanStack Start route loader:
 *   const supabase = getServerSupabase(request, response);
 *   const { data: { user } } = await supabase.auth.getUser();
 */
export function getServerSupabase(request: Request, response: Response) {
  return createServerClient<Database>(SUPABASE_URL, SUPABASE_KEY, {
    cookies: {
      getAll() {
        const header = request.headers.get("cookie") ?? "";
        return header.split(";").flatMap((part) => {
          const trimmed = part.trim();
          if (!trimmed) return [];
          const eq = trimmed.indexOf("=");
          if (eq === -1) return [];
          return [
            {
              name: trimmed.slice(0, eq).trim(),
              value: decodeURIComponent(trimmed.slice(eq + 1).trim()),
            },
          ];
        });
      },
      setAll(cookiesToSet) {
        for (const { name, value, options } of cookiesToSet) {
          response.headers.append("set-cookie", serializeCookie(name, value, options));
        }
      },
    },
  });
}

// ─── cookie serialiser (no extra deps) ─────────────────────────────
type CookieOpts = {
  maxAge?: number;
  domain?: string;
  path?: string;
  expires?: Date;
  httpOnly?: boolean;
  secure?: boolean;
  sameSite?: boolean | "lax" | "strict" | "none";
};

function serializeCookie(name: string, value: string, options: CookieOpts): string {
  const parts: string[] = [`${name}=${encodeURIComponent(value)}`];
  if (options.maxAge !== undefined) parts.push(`Max-Age=${options.maxAge}`);
  if (options.domain) parts.push(`Domain=${options.domain}`);
  if (options.path) parts.push(`Path=${options.path}`);
  if (options.expires) parts.push(`Expires=${options.expires.toUTCString()}`);
  if (options.httpOnly) parts.push("HttpOnly");
  if (options.secure) parts.push("Secure");
  if (options.sameSite) {
    const sv = options.sameSite === true ? "Strict" : options.sameSite;
    parts.push(`SameSite=${sv}`);
  }
  return parts.join("; ");
}
