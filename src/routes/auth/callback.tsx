import { createFileRoute, useRouter } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useSupabase } from "@/lib/auth/session";

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
    <div className="relative min-h-screen bg-[#faf9f6] font-['Inter'] text-[#1a1c1a] flex items-center justify-center">
      <div className="text-center">
        {error ? (
          <>
            <p className="text-[10px] uppercase tracking-[0.32em] text-[#D4AF37] mb-4">
              · Sign-in error ·
            </p>
            <p className="font-['Noto_Serif'] italic text-base text-[#4d4635] mb-6">
              {error}
            </p>
            <a
              href="/auth/login"
              className="text-[10px] uppercase tracking-[0.22em] text-[#7f7663] hover:text-[#D4AF37]"
            >
              ← Back to sign in
            </a>
          </>
        ) : (
          <p className="font-['Noto_Serif'] italic text-base text-[#4d4635]">
            Signing you in…
          </p>
        )}
      </div>
    </div>
  );
}
