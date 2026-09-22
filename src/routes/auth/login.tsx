import { createFileRoute, Link, useRouter } from "@tanstack/react-router";
import { useState } from "react";
import { useSupabase } from "@/lib/auth/session";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Mail, Lock, Sparkles, ArrowRight, Loader2 } from "lucide-react";

export const Route = createFileRoute("/auth/login")({ component: Login });

type Mode = "password" | "magic";

function Login() {
  const supabase = useSupabase();
  const router = useRouter();
  const [mode, setMode] = useState<Mode>("password");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [sent, setSent] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      if (mode === "password") {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
        router.navigate({ to: "/" });
      } else {
        const { error } = await supabase.auth.signInWithOtp({
          email,
          options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
        });
        if (error) throw error;
        setSent(true);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "Something went wrong.");
    } finally {
      setSubmitting(false);
    }
  };

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
            <CardTitle className="font-display text-2xl tracking-tight">Welcome back</CardTitle>
            <CardDescription>Sign in to your account to continue</CardDescription>
          </CardHeader>

          <CardContent>
            {sent ? (
              <div className="space-y-3 text-center py-4">
                <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-accent/10">
                  <Mail className="h-5 w-5 text-accent" />
                </div>
                <p className="text-sm text-muted-foreground leading-relaxed">
                  We sent a sign-in link to{" "}
                  <span className="font-medium text-foreground">{email}</span>.
                  <br />
                  Check your inbox to continue.
                </p>
              </div>
            ) : (
              <form onSubmit={handleSubmit} className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="login-email">Email</Label>
                  <div className="relative">
                    <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                    <Input
                      id="login-email"
                      type="email"
                      value={email}
                      onChange={(e) => setEmail(e.target.value)}
                      placeholder="you@example.com"
                      autoComplete="email"
                      autoFocus
                      required
                      className="pl-9"
                    />
                  </div>
                </div>

                {mode === "password" && (
                  <div className="space-y-2">
                    <Label htmlFor="login-password">Password</Label>
                    <div className="relative">
                      <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                      <Input
                        id="login-password"
                        type="password"
                        value={password}
                        onChange={(e) => setPassword(e.target.value)}
                        placeholder="••••••••"
                        autoComplete="current-password"
                        required
                        minLength={8}
                        className="pl-9"
                      />
                    </div>
                  </div>
                )}

                {error && <p className="text-sm text-destructive">{error}</p>}

                <Button type="submit" disabled={submitting} className="w-full" size="lg">
                  {submitting ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : mode === "password" ? (
                    <>
                      Sign In
                      <ArrowRight className="h-4 w-4" />
                    </>
                  ) : (
                    <>
                      <Sparkles className="h-4 w-4" />
                      Send Magic Link
                    </>
                  )}
                </Button>

                {/* Divider */}
                <div className="relative my-2">
                  <div className="absolute inset-0 flex items-center">
                    <div className="w-full border-t border-border" />
                  </div>
                  <div className="relative flex justify-center text-xs">
                    <span className="bg-card px-2 text-muted-foreground">or</span>
                  </div>
                </div>

                <Button
                  type="button"
                  variant="outline"
                  className="w-full"
                  onClick={() => {
                    setMode(mode === "password" ? "magic" : "password");
                    setError(null);
                  }}
                >
                  {mode === "password" ? "Use a magic link instead" : "Use password instead"}
                </Button>
              </form>
            )}
          </CardContent>

          <CardFooter className="justify-center border-t border-border/50 pt-6">
            <p className="text-sm text-muted-foreground">
              No account yet?{" "}
              <Link
                to="/auth/signup"
                className="font-medium text-foreground transition-colors hover:text-accent"
              >
                Create one
                <ArrowRight className="ml-0.5 inline h-3 w-3" />
              </Link>
            </p>
          </CardFooter>
        </Card>

        {/* Footer legal line */}
        <p className="mt-6 text-center text-[11px] text-muted-foreground/70">
          By signing in you agree to our Terms of Service.
        </p>
      </div>
    </div>
  );
}
