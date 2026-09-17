import { createSupabaseAuthorizer } from "./core.mjs";

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing required environment value: ${name}`);
  return value;
}

const authorize = createSupabaseAuthorizer({
  supabaseUrl: requiredEnvironment("SUPABASE_URL"),
  publishableKey: requiredEnvironment("SUPABASE_PUBLISHABLE_KEY"),
  fetchImpl: fetch,
});

export const handler = (event) => authorize(event);
