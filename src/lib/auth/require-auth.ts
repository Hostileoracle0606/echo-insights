import { redirect } from "@tanstack/react-router";
import { createServerFn } from "@tanstack/react-start";
import { getRequest, getResponse } from "@tanstack/react-start/server";
import { getServerSupabase } from "@/lib/supabase/server";

export const fetchAuthUser = createServerFn({ method: "GET" }).handler(async () => {
  try {
    const request = getRequest();
    const rawResponse = getResponse();
    const responseShim = { headers: rawResponse.headers } as unknown as Response;
    const supabase = getServerSupabase(request, responseShim);
    const {
      data: { user },
    } = await supabase.auth.getUser();
    return user;
  } catch (e) {
    console.warn("Failed to reach Supabase in fetchAuthUser:", e);
    return null;
  }
});

export async function requireAuthOrRedirect() {
  const user = await fetchAuthUser();
  if (!user) {
    throw redirect({ to: "/auth/login" });
  }
  return user;
}
