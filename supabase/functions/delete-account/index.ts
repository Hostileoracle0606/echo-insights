import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { handleDeleteAccount } from "./handler.ts";

serve((req) =>
  handleDeleteAccount(req, {
    async verifiedUserId(authorization) {
      const supa = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_ANON_KEY")!,
        { global: { headers: { Authorization: authorization } } },
      );
      const { data: { user }, error } = await supa.auth.getUser();
      return error || !user ? null : user.id;
    },
    async deleteUser(userId) {
      const admin = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
        { auth: { autoRefreshToken: false, persistSession: false } },
      );
      const { error } = await admin.auth.admin.deleteUser(userId);
      return { error };
    },
    log: (fields) => console.log(JSON.stringify(fields)),
  })
);
