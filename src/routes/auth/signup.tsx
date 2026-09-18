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
import { Mail, Lock, User, ArrowRight, Loader2, CheckCircle2 } from "lucide-react";

export const Route = createFileRoute("/auth/signup")({ component: Signup });

function Signup() {
  const supabase = useSupabase();
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [needsConfirmation, setNeedsConfirmation] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const { data, error } = await supabase.auth.signUp({
        email,
        password,
        options: {
          data: { display_name: displayName },
          emailRedirectTo: `${window.location.origin}/auth/callback`,
        },
      });
      if (error) throw error;
      if (data.session) {
        router.navigate({ to: "/" });
      } else {
        setNeedsConfirmation(true);
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
            <CardTitle className="font-display text-2xl tracking-tight">
              Create your account
            </CardTitle>
            <CardDescription>Start building your personal knowledge graph</CardDescription>
          </CardHeader>

          <CardContent>
            {needsConfirmation ? (
              <div className="space-y-3 text-center py-4">
                <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-accent/10">
                  <CheckCircle2 className="h-5 w-5 text-accent" />
                </div>
                <p className="text-sm text-muted-foreground leading-relaxed">
                  We sent a confirmation link to{" "}
                  <span className="font-medium text-foreground">{email}</span>.
                  <br />
                  Check your inbox to activate your account.
                </p>
              </div>
            ) : (
              <form onSubmit={handleSubmit} className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="signup-name">Name</Label>
                  <div className="relative">
                    <User className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                    <Input
                      id="signup-name"
                      type="text"
                      value={displayName}
                      onChange={(e) => setDisplayName(e.target.value)}
                      placeholder="Your name"
                      autoComplete="name"
                      autoFocus
                      required
                      minLength={1}
                      className="pl-9"
                    />
                  </div>
                </div>

                <div className="space-y-2">
                  <Label htmlFor="signup-email">Email</Label>
                  <div className="relative">
                    <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                    <Input
                      id="signup-email"
                      type="email"
                      value={email}
                      onChange={(e) => setEmail(e.target.value)}
                      placeholder="you@example.com"
                      autoComplete="email"
                      required
                      className="pl-9"
                    />
                  </div>
                </div>

                <div className="space-y-2">
                  <Label htmlFor="signup-password">Password</Label>
                  <div className="relative">
                    <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                    <Input
                      id="signup-password"
                      type="password"
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                      placeholder="At least 8 characters"
                      autoComplete="new-password"
                      required
                      minLength={8}
                      className="pl-9"
                    />
                  </div>
                </div>

                {error && <p className="text-sm text-destructive">{error}</p>}

                <Button type="submit" disabled={submitting} className="w-full" size="lg">
                  {submitting ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <>
                      Create Account
                      <ArrowRight className="h-4 w-4" />
                    </>
                  )}
                </Button>
              </form>
            )}
          </CardContent>

          <CardFooter className="justify-center border-t border-border/50 pt-6">
            <p className="text-sm text-muted-foreground">
              Already have an account?{" "}
              <Link
                to="/auth/login"
                className="font-medium text-foreground transition-colors hover:text-accent"
              >
                Sign in
                <ArrowRight className="ml-0.5 inline h-3 w-3" />
              </Link>
            </p>
          </CardFooter>
        </Card>

        {/* Footer legal line */}
        <p className="mt-6 text-center text-[11px] text-muted-foreground/70">
          By creating an account you agree to our Terms of Service.
        </p>
      </div>
    </div>
  );
}
