import { createFileRoute, useRouter } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useSupabase } from "@/lib/auth/session";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Loader2, AlertCircle, ArrowLeft } from "lucide-react";
import { Link } from "@tanstack/react-router";

export const Route = createFileRoute("/auth/callback")({ component: Callback });

function Callback() {
  const supabase = useSupabase();
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const code = params.get("code");
    if (!code) {
      setError("No code in callback URL.");
      return;
    }
    (async () => {
      const { error } = await supabase.auth.exchangeCodeForSession(code);
      if (error) {
        setError(error.message);
        return;
      }
      router.navigate({ to: "/" });
    })();
  }, [supabase, router]);

  return (
    <div className="relative flex min-h-screen items-center justify-center px-4">
      {/* Wordmark */}
      <Link
        to="/"
        className="fixed left-6 top-6 z-50 font-display text-xl font-medium tracking-wide text-foreground md:left-10 md:top-8"
      >
        Lumen<span className="text-accent">.</span>
      </Link>

      <div className="w-full max-w-sm">
        <Card className="border-border/60 shadow-[var(--shadow-paper)]">
          <CardHeader className="space-y-1 pb-4">
            <CardTitle className="font-display text-2xl tracking-tight">
              {error ? "Sign-in failed" : "Signing you in"}
            </CardTitle>
            <CardDescription>
              {error ? "We couldn't complete your sign-in" : "Verifying your credentials…"}
            </CardDescription>
          </CardHeader>

          <CardContent>
            <div className="flex flex-col items-center gap-4 py-4">
              {error ? (
                <>
                  <div className="flex h-12 w-12 items-center justify-center rounded-full bg-destructive/10">
                    <AlertCircle className="h-5 w-5 text-destructive" />
                  </div>
                  <p className="text-center text-sm text-muted-foreground leading-relaxed">
                    {error}
                  </p>
                  <Button variant="outline" asChild className="mt-2">
                    <Link to="/auth/login">
                      <ArrowLeft className="h-4 w-4" />
                      Back to sign in
                    </Link>
                  </Button>
                </>
              ) : (
                <>
                  <Loader2 className="h-8 w-8 animate-spin text-accent" />
                  <p className="text-sm text-muted-foreground">One moment…</p>
                </>
              )}
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
