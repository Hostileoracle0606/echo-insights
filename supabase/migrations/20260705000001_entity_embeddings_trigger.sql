create extension if not exists pg_cron;

-- Fire once per bulk entity insert (statement level). Transition table gives the
-- affected notebook_ids without a per-row storm; user_id is resolved in the fn.
create or replace function public.enqueue_embed_entities()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record;
  v_url text := current_setting('app.embed_entities_url', true);
  v_secret text := current_setting('app.embed_internal_secret', true);
begin
  -- Config not set yet → skip quietly (never break the save); cron reconcile covers it.
  -- Guard BOTH: an empty secret would POST a blank x-internal-secret → 403 storm.
  if v_url is null or v_url = '' or v_secret is null or v_secret = '' then return null; end if;
  for r in select distinct notebook_id from new_rows loop
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
      body    := jsonb_build_object('notebookId', r.notebook_id)
    );
  end loop;
  return null;
end $$;

create trigger entities_embed_enqueue
  after insert on public.entities
  referencing new table as new_rows
  for each statement execute function public.enqueue_embed_entities();

-- Backstop sweep A: poke EVERY notebook that has entities. embed-entities is
-- idempotent and does the precise staleness check (missing OR content_hash OR
-- embedding_model changed) as the single source of truth — so this one query
-- catches dropped webhooks, description edits, AND model migrations without
-- duplicating the SHA-256 / model-id logic in SQL. (Scale-up, if invocation
-- volume ever matters: narrow to notebooks with a provably-stale row using
-- pgcrypto digest + an app.embedding_model setting.)
create or replace function public.embed_reconcile_sweep()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record;
  v_url text := current_setting('app.embed_entities_url', true);
  v_secret text := current_setting('app.embed_internal_secret', true);
begin
  if v_url is null or v_url = '' or v_secret is null or v_secret = '' then return; end if;
  for r in select distinct notebook_id from public.entities loop
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
      body    := jsonb_build_object('notebookId', r.notebook_id));
  end loop;
end $$;

-- Backstop sweep B: global orphan prune (catches clearState / zero-entity saves
-- that never fire the insert trigger).
create or replace function public.embed_orphan_prune()
returns void language sql security definer set search_path = public, pg_temp as $$
  delete from public.entity_embeddings ee
  where not exists (
    select 1 from public.entities e
    where e.notebook_id = ee.notebook_id and e.id = ee.entity_id);
$$;

-- Privileged helpers: Postgres grants EXECUTE to PUBLIC by default and Supabase
-- can expose public functions as RPCs. Revoke so no user can trigger a
-- system-wide sweep or a privileged delete. cron (function owner) still runs them.
revoke all on function public.enqueue_embed_entities() from public, anon, authenticated;
revoke all on function public.embed_reconcile_sweep() from public, anon, authenticated;
revoke all on function public.embed_orphan_prune() from public, anon, authenticated;

-- Reconcile is a full sweep now → every 15 min (trigger handles the hot path).
select cron.schedule('embed-reconcile', '*/15 * * * *', 'select public.embed_reconcile_sweep()');
select cron.schedule('embed-orphan-prune', '*/30 * * * *', 'select public.embed_orphan_prune()');
