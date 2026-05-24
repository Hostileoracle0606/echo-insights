import { createFileRoute, Link, useRouter } from "@tanstack/react-router";
import { useState } from "react";
import { useSupabase } from "@/lib/auth/session";
import { cn } from "@/lib/utils";

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
        // No email confirmation required — proceed to app.
        router.navigate({ to: "/" });
      } else {
        // Email confirmation required — show inbox prompt.
        setNeedsConfirmation(true);
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
            · Create account ·
          </p>
          <h1 className="mb-8 font-['Noto_Serif'] text-[36px] font-medium leading-[1.15] tracking-[-0.02em] text-[#1a1c1a] md:text-[44px]">
            Make a place to think.
          </h1>

          {needsConfirmation ? (
            <p className="font-['Noto_Serif'] italic text-base leading-[1.6] text-[#4d4635]">
              Check your inbox — we sent a confirmation link to <strong>{email}</strong>.
            </p>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-5">
              <input
                type="text"
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                placeholder="Your name"
                autoComplete="name"
                autoFocus
                required
                minLength={1}
                className="w-full border bg-transparent px-6 py-4 font-['Noto_Serif'] text-base text-[#1a1c1a] border-[#1a1c1a]/30 transition-colors duration-300 placeholder:text-[#7f7663]/70 placeholder:font-['Inter'] placeholder:text-sm placeholder:tracking-wider focus:border-[#1a1c1a]/70 focus:outline-none"
              />
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@example.com"
                autoComplete="email"
                required
                className="w-full border bg-transparent px-6 py-4 font-['Noto_Serif'] text-base text-[#1a1c1a] border-[#1a1c1a]/30 transition-colors duration-300 placeholder:text-[#7f7663]/70 placeholder:font-['Inter'] placeholder:text-sm placeholder:tracking-wider focus:border-[#1a1c1a]/70 focus:outline-none"
              />
              <input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="Password — at least 8 characters"
                autoComplete="new-password"
                required
                minLength={8}
                className="w-full border bg-transparent px-6 py-4 font-['Noto_Serif'] text-base text-[#1a1c1a] border-[#1a1c1a]/30 transition-colors duration-300 placeholder:text-[#7f7663]/70 placeholder:font-['Inter'] placeholder:text-sm placeholder:tracking-wider focus:border-[#1a1c1a]/70 focus:outline-none"
              />

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
                {submitting ? "…" : "Create Account"}
              </button>
            </form>
          )}

          <div className="mx-auto mt-12 h-px w-1/3 bg-gradient-to-r from-transparent via-[#D4AF37]/40 to-transparent" />

          <p className="mt-8 text-[10px] uppercase tracking-[0.22em] text-[#7f7663]">
            Already have an account?{" "}
            <Link
              to="/auth/login"
              className="transition-colors duration-300 hover:text-[#D4AF37]"
            >
              Sign in →
            </Link>
          </p>
        </div>
      </main>
    </div>
  );
}
