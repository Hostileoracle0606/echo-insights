import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session, User, SupabaseClient } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase/browser";
import type { Database } from "@/lib/supabase/types";

type SessionContextValue = {
  session: Session | null;
  user: User | null;
  supabase: SupabaseClient<Database>;
};

const SessionContext = createContext<SessionContextValue | null>(null);

/**
 * Wrap the app once at the root. `initialSession` is whatever the SSR
 * loader saw — so the first paint already knows whether the user is
 * authenticated, avoiding a flash of signed-out UI.
 */
export function SessionProvider({
  initialSession,
  children,
}: {
  initialSession: Session | null;
  children: ReactNode;
}) {
  const [session, setSession] = useState<Session | null>(initialSession);

  useEffect(() => {
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next);
    });
    return () => {
      subscription.unsubscribe();
    };
  }, []);

  return (
    <SessionContext.Provider
      value={{ session, user: session?.user ?? null, supabase }}
    >
      {children}
    </SessionContext.Provider>
  );
}

export function useSession(): SessionContextValue {
  const ctx = useContext(SessionContext);
  if (!ctx) {
    throw new Error("useSession must be called inside <SessionProvider>");
  }
  return ctx;
}

export function useSupabase(): SupabaseClient<Database> {
  return useSession().supabase;
}
