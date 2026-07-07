-- ALTER DATABASE ... SET is not permitted in the Supabase SQL editor (the
-- editor role is not a true superuser → ERROR 42501). Read the trigger/cron
-- config from Vault instead — the Supabase-blessed secret store for the
-- pg_net → edge-function pattern. The two secrets are created out-of-band via
-- `select vault.create_secret(...)` in the SQL editor (never committed to git).
create extension if not exists supabase_vault;

-- Trigger: fire embed-entities once per bulk entity insert. Config from Vault.
create or replace function public.enqueue_embed_entities()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record;
  v_url text := (select decrypted_secret from vault.decrypted_secrets where name = 'embed_entities_url');
  v_secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'embed_internal_secret');
begin
  -- Skip quietly until both Vault secrets exist (empty secret → 403 storm).
  if v_url is null or v_url = '' or v_secret is null or v_secret = '' then return null; end if;
  for r in select distinct notebook_id from new_rows loop
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
      body    := jsonb_build_object('notebookId', r.notebook_id));
  end loop;
  return null;
end $$;

-- Cron reconcile sweep: poke every notebook with entities. Config from Vault.
create or replace function public.embed_reconcile_sweep()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record;
  v_url text := (select decrypted_secret from vault.decrypted_secrets where name = 'embed_entities_url');
  v_secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'embed_internal_secret');
begin
  if v_url is null or v_url = '' or v_secret is null or v_secret = '' then return; end if;
  for r in select distinct notebook_id from public.entities loop
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
      body    := jsonb_build_object('notebookId', r.notebook_id));
  end loop;
end $$;
