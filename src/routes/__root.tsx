import { Outlet, Link, createRootRoute, HeadContent, Scripts } from "@tanstack/react-router";
import { createServerFn } from "@tanstack/react-start";
import { getRequest, getResponse } from "@tanstack/react-start/server";
import type { Session } from "@supabase/supabase-js";
import { SessionProvider } from "@/lib/auth/session";
import { getServerSupabase } from "@/lib/supabase/server";
import appCss from "../styles.css?url";

function NotFoundComponent() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-7xl font-display text-foreground">404</h1>
        <h2 className="mt-4 text-xl font-display text-foreground">Page not found</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          The page you're looking for doesn't exist.
        </p>
        <div className="mt-6">
          <Link
            to="/"
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:opacity-90"
          >
            Go home
          </Link>
        </div>
      </div>
    </div>
  );
}

const getInitialSession = createServerFn({ method: "GET" }).handler(
  async (): Promise<Session | null> => {
    const request = getRequest();
    const rawResponse = getResponse();
    // getResponse() returns { headers: Headers, ... } — we only need
    // response.headers.append() inside getServerSupabase, so a minimal
    // shim satisfies the interface at runtime.
    const responseShim = { headers: rawResponse.headers } as unknown as Response;
    const supabase = getServerSupabase(request, responseShim);
    const { data: { session } } = await supabase.auth.getSession();
    return session;
  },
);

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "Lumen — A voice-first journal that thinks with you" },
      { name: "description", content: "Speak your day. Lumen listens, builds a living knowledge graph of the people, places and ideas in your life, and asks you what's missing. Export to Obsidian." },
      { name: "author", content: "Lumen" },
      { property: "og:title", content: "Lumen — A voice-first journal" },
      { property: "og:description", content: "Speak. Lumen builds a knowledge graph of your life and asks what's missing." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
    links: [
      { rel: "stylesheet", href: appCss },
    ],
  }),
  loader: async () => {
    const session = await getInitialSession();
    return { session };
  },
  shellComponent: RootShell,
  component: RouteComponent,
  notFoundComponent: NotFoundComponent,
});

function RouteComponent() {
  const { session } = Route.useLoaderData() as { session: Session | null };
  return (
    <SessionProvider initialSession={session}>
      <Outlet />
    </SessionProvider>
  );
}

function RootShell({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head><HeadContent /></head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}
