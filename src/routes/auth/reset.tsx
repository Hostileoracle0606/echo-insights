import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useSupabase } from "@/lib/auth/session";
import {
  MIN_PASSWORD_LENGTH,
  parseRecoveryLink,
  passwordProblem,
  updateErrorMessage,
} from "@/lib/auth/password-reset";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Checkbox } from "@/components/ui/checkbox";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { AlertCircle, CheckCircle2, Loader2, Lock, Mail } from "lucide-react";

export const Route = createFileRoute("/auth/reset")({ component: ResetPassword });

type Stage =
  | { name: "verifying" }
  | { name: "form"; email: string | null }
  | { name: "expired" }
  | { name: "done"; signedOutEverywhere: boolean };

/**
 * Where a password-recovery email lands (see src/lib/auth/password-reset.ts).
 * verifyOtp → new password → updateUser → sign out. The iOS app has no deep
 * link back, so the finished state tells the user to return to Lumen.
 */
function ResetPassword() {
  const supabase = useSupabase();
  const [stage, setStage] = useState<Stage>({ name: "verifying" });

  useEffect(() => {
    const link = parseRecoveryLink(window.location.search, window.location.hash);
    // The token is single-use; keep it out of history and any later copy of the URL.
    window.history.replaceState(null, "", window.location.pathname);
    if (link.kind !== "token") {
      setStage({ name: "expired" });
      return;
    }
    let cancelled = false;
    (async () => {
      const { data, error } = await supabase.auth.verifyOtp({
        type: "recovery",
        token_hash: link.tokenHash,
      });
      if (cancelled) return;
      if (error || !data.session) {
        setStage({ name: "expired" });
        return;
      }
      setStage({ name: "form", email: data.user?.email ?? null });
    })();
    return () => {
      cancelled = true;
    };
  }, [supabase]);

  const title = {
    verifying: "Checking your link",
    form: "Choose a new password",
    expired: "This link has expired",
    done: "Password updated",
  }[stage.name];

  return (
    <div className="relative flex min-h-screen items-center justify-center px-4">
      <Link
        to="/"
        className="fixed left-6 top-6 z-50 font-display text-xl font-medium tracking-wide text-foreground md:left-10 md:top-8"
      >
        Lumen<span className="text-accent">.</span>
      </Link>

      <div className="w-full max-w-sm">
        <Card className="border-border/60 shadow-[var(--shadow-paper)]">
          <CardHeader className="space-y-1 pb-4">
            <CardTitle className="font-display text-2xl tracking-tight">{title}</CardTitle>
            {stage.name === "form" && stage.email && (
              <CardDescription>For {stage.email}</CardDescription>
            )}
          </CardHeader>
          <CardContent>
            {stage.name === "verifying" && (
              <div className="flex flex-col items-center gap-4 py-4">
                <Loader2 className="h-8 w-8 animate-spin text-accent" />
                <p className="text-sm text-muted-foreground">One moment…</p>
              </div>
            )}
            {stage.name === "form" && (
              <NewPasswordForm
                onDone={(signedOutEverywhere) => setStage({ name: "done", signedOutEverywhere })}
                onExpired={() => setStage({ name: "expired" })}
              />
            )}
            {stage.name === "expired" && <ResendForm />}
            {stage.name === "done" && (
              <div className="space-y-4 py-2 text-center">
                <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-accent/10">
                  <CheckCircle2 className="h-5 w-5 text-accent" />
                </div>
                <p className="text-sm leading-relaxed text-muted-foreground">
                  Open the Lumen app on your iPhone and sign in with your new password.
                  {stage.signedOutEverywhere && " You've been signed out everywhere else."}
                </p>
                <Button variant="outline" asChild className="w-full">
                  <Link to="/auth/login">Sign in on the web instead</Link>
                </Button>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function NewPasswordForm({
  onDone,
  onExpired,
}: {
  onDone: (signedOutEverywhere: boolean) => void;
  onExpired: () => void;
}) {
  const supabase = useSupabase();
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [everywhere, setEverywhere] = useState(true);
  const [touched, setTouched] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const problem = passwordProblem(password, confirm);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setTouched(true);
    if (problem) return;
    setError(null);
    setSubmitting(true);
    try {
      const { error: updateError } = await supabase.auth.updateUser({ password });
      if (updateError) {
        if (updateError.code === "session_not_found" || updateError.code === "session_expired") {
          onExpired();
          return;
        }
        setError(updateErrorMessage(updateError));
        return;
      }
      // Either way this browser's recovery session ends; "global" also revokes
      // every other session, including the app's.
      await supabase.auth.signOut({ scope: everywhere ? "global" : "local" });
      onDone(everywhere);
    } catch {
      setError(updateErrorMessage(null));
    } finally {
      setSubmitting(false);
    }
  };

  const shownProblem = touched && confirm.length > 0 ? problem : null;

  return (
    <form onSubmit={handleSubmit} className="space-y-4" noValidate>
      <div className="space-y-2">
        <Label htmlFor="reset-password">New password</Label>
        <div className="relative">
          <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            id="reset-password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder={`At least ${MIN_PASSWORD_LENGTH} characters`}
            autoComplete="new-password"
            autoFocus
            required
            minLength={MIN_PASSWORD_LENGTH}
            className="pl-9"
          />
        </div>
      </div>
      <div className="space-y-2">
        <Label htmlFor="reset-confirm">Confirm password</Label>
        <div className="relative">
          <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            id="reset-confirm"
            type="password"
            value={confirm}
            onChange={(e) => {
              setConfirm(e.target.value);
              setTouched(true);
            }}
            autoComplete="new-password"
            required
            aria-invalid={shownProblem ? true : undefined}
            aria-describedby={shownProblem ? "reset-problem" : undefined}
            className="pl-9"
          />
        </div>
        {shownProblem && (
          <p id="reset-problem" className="text-sm text-destructive">
            {shownProblem}
          </p>
        )}
      </div>
      <div className="flex items-center gap-2">
        <Checkbox
          id="reset-everywhere"
          checked={everywhere}
          onCheckedChange={(value) => setEverywhere(value === true)}
        />
        <Label htmlFor="reset-everywhere" className="font-normal">
          Sign out of all other devices
        </Label>
      </div>
      {error && (
        <div className="flex items-start gap-2 rounded-md bg-destructive/10 p-3 text-sm text-destructive">
          <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
          <span>{error}</span>
        </div>
      )}
      <Button type="submit" className="w-full" disabled={submitting || problem !== null}>
        {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : "Update password"}
      </Button>
    </form>
  );
}

function ResendForm() {
  const supabase = useSupabase();
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const { error: sendError } = await supabase.auth.resetPasswordForEmail(email.trim(), {
        redirectTo: `${window.location.origin}/auth/reset`,
      });
      if (sendError) {
        setError(
          sendError.status === 429
            ? sendError.message
            : "Couldn't send the link. Check your connection and try again.",
        );
        return;
      }
      setSent(true);
    } catch {
      setError("Couldn't send the link. Check your connection and try again.");
    } finally {
      setSubmitting(false);
    }
  };

  if (sent) {
    return (
      <p className="py-2 text-sm leading-relaxed text-muted-foreground">
        If an account exists for <span className="font-medium text-foreground">{email.trim()}</span>
        , a new reset link is on its way.
      </p>
    );
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <p className="text-sm leading-relaxed text-muted-foreground">
        Reset links work once, for one hour. Send a fresh one to your email.
      </p>
      <div className="space-y-2">
        <Label htmlFor="reset-email">Email</Label>
        <div className="relative">
          <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            id="reset-email"
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
      {error && <p className="text-sm text-destructive">{error}</p>}
      <Button type="submit" className="w-full" disabled={submitting}>
        {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : "Send a new link"}
      </Button>
    </form>
  );
}
