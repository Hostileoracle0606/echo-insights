import { createFileRoute, Link, useRouter } from "@tanstack/react-router";
import { useState } from "react";
import { useSupabase } from "@/lib/auth/session";
import { cn } from "@/lib/utils";

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
        router.navigate({ to: "/app" });
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
    <div className="relative min-h-screen bg-[#faf9f6] font-['Inter'] text-[#1a1c1a]">
      <Link
        to="/"
        className="fixed left-8 top-8 z-50 font-['Noto_Serif'] text-2xl font-medium tracking-[0.18em] text-[#1a1c1a] md:left-12 md:top-10"
      >
        Lumen<span className="text-[#D4AF37]">.</span>
      </Link>

      <main className="relative z-10 flex min-h-screen items-center justify-center px-6 pt-28 pb-12">
        <div className="mx-auto w-full max-w-md text-center">
          <p className="mb-6 text-[10px] uppercase tracking-[0.32em] text-[#D4AF37]">
            · Sign in ·
          </p>
          <h1 className="mb-8 font-['Noto_Serif'] text-[36px] font-medium leading-[1.15] tracking-[-0.02em] text-[#1a1c1a] md:text-[44px]">
            Welcome back.
          </h1>

          {sent ? (
            <p className="font-['Noto_Serif'] italic text-base leading-[1.6] text-[#4d4635]">
              Check your inbox — we sent a sign-in link to <strong>{email}</strong>.
            </p>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-5">
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@example.com"
                autoComplete="email"
                autoFocus
                required
                className="w-full border bg-transparent px-6 py-4 font-['Noto_Serif'] text-base text-[#1a1c1a] border-[#1a1c1a]/30 transition-colors duration-300 placeholder:text-[#7f7663]/70 placeholder:font-['Inter'] placeholder:text-sm placeholder:tracking-wider focus:border-[#1a1c1a]/70 focus:outline-none"
              />

              {mode === "password" && (
                <input
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="Password"
                  autoComplete="current-password"
                  required
                  minLength={8}
                  className="w-full border bg-transparent px-6 py-4 font-['Noto_Serif'] text-base text-[#1a1c1a] border-[#1a1c1a]/30 transition-colors duration-300 placeholder:text-[#7f7663]/70 placeholder:font-['Inter'] placeholder:text-sm placeholder:tracking-wider focus:border-[#1a1c1a]/70 focus:outline-none"
                />
              )}

              {error && (
                <p className="font-['Inter'] text-sm text-red-700">{error}</p>
              )}

              <button
                type="submit"
                disabled={submitting}
                className={cn(
                  "group relative inline-flex items-center justify-center",
                  "border border-[#1a1c1a]/60 bg-transparent",
                  "px-10 py-3.5 text-[11px] uppercase tracking-[0.32em] text-[#1a1c1a]",
                  "transition-all duration-500 ease-[cubic-bezier(0.4,0,0.2,1)]",
                  "hover:border-[#1a1c1a] hover:bg-[#1a1c1a] hover:text-[#faf9f6]",
                  "disabled:opacity-40 disabled:cursor-not-allowed",
                )}
              >
                {submitting
                  ? "…"
                  : mode === "password"
                  ? "Sign In"
                  : "Send Magic Link"}
              </button>

              <button
                type="button"
                onClick={() => {
                  setMode(mode === "password" ? "magic" : "password");
                  setError(null);
                }}
                className="block w-full mt-4 text-[10px] uppercase tracking-[0.22em] text-[#7f7663] transition-colors duration-300 hover:text-[#D4AF37]"
              >
                {mode === "password"
                  ? "Use a magic link instead →"
                  : "← Use password instead"}
              </button>
            </form>
          )}

          <div className="mx-auto mt-12 h-px w-1/3 bg-gradient-to-r from-transparent via-[#D4AF37]/40 to-transparent" />

          <p className="mt-8 text-[10px] uppercase tracking-[0.22em] text-[#7f7663]">
            No account yet?{" "}
            <Link
              to="/auth/signup"
              className="transition-colors duration-300 hover:text-[#D4AF37]"
            >
              Create one →
            </Link>
          </p>
        </div>
      </main>
    </div>
  );
}
