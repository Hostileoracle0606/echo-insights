-- Auto-forget old transcripts (LM-51).
--
-- A per-user setting: keep transcripts forever (null), or 90, 30 or 7 days. A
-- daily pg_cron job deletes conversation_turns and journal_entries older than
-- each user's setting, measured from the row's created_at. Cards, entities,
-- relations, follow-ups, asked questions, embeddings and session briefs are
-- not touched: they are what Lumen remembers, not the transcript.
--
-- Reopening a notebook whose turns have expired works: the app already opens
-- with an empty history when no turns come back, and the graph and card load
-- from their own tables. A later save of that notebook (a revision-checked
-- full-state commit) rewrites its journal_entries from the client's state, so
-- an expired entry does not come back.
--
-- The setting lives on profiles (one row per user, owner RLS, cascade from
-- auth.users), so the deletion guard already covers it. Writes go only
-- through set_transcript_retention, which validates the value; the column
-- also has a CHECK, and direct UPDATE on it is revoked from API roles.

alter table public.profiles
  add column transcript_retention_days integer
    constraint profiles_transcript_retention_days_check
    check (transcript_retention_days in (90, 30, 7));

comment on column public.profiles.transcript_retention_days is
  'Days to keep conversation_turns and journal_entries; null keeps them forever.';

-- Profiles are written by the app only for display_name today. Make the new
-- column RPC-only by narrowing the table-level UPDATE to the other columns.
revoke update on public.profiles from authenticated, anon;
grant update (display_name) on public.profiles to authenticated;

create index if not exists conversation_turns_created_at_idx
  on public.conversation_turns (created_at);
create index if not exists journal_entries_created_at_idx
  on public.journal_entries (created_at);

-- ────────────────────────────────────────────────────────────
-- set_transcript_retention: the only way a user changes the setting.
-- null = forever. Anything but null / 90 / 30 / 7 is 22023.
-- ────────────────────────────────────────────────────────────
create or replace function public.set_transcript_retention(p_days integer)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  if p_days is not null and p_days not in (90, 30, 7) then
    raise exception 'transcript retention must be 90, 30, 7 or null'
      using errcode = '22023';
  end if;

  insert into public.profiles (user_id, transcript_retention_days)
    values (v_uid, p_days)
    on conflict (user_id)
    do update set transcript_retention_days = excluded.transcript_retention_days;

  return p_days;
end;
$$;

revoke all on function public.set_transcript_retention(integer) from public, anon;
grant execute on function public.set_transcript_retention(integer) to authenticated;

-- ────────────────────────────────────────────────────────────
-- forget_old_transcripts: the daily sweep. Not callable through the API.
-- Deletes in batches so one run never holds a long lock; returns counts only.
-- ────────────────────────────────────────────────────────────
create or replace function public.forget_old_transcripts(p_batch integer default 5000)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_turns bigint := 0;
  v_entries bigint := 0;
  v_n bigint;
begin
  loop
    delete from public.conversation_turns
     where ctid in (
       select t.ctid
         from public.conversation_turns t
         join public.profiles p on p.user_id = t.user_id
        where p.transcript_retention_days is not null
          and t.created_at < now() - make_interval(days => p.transcript_retention_days)
        limit p_batch);
    get diagnostics v_n = row_count;
    v_turns := v_turns + v_n;
    exit when v_n < p_batch;
  end loop;

  loop
    delete from public.journal_entries
     where ctid in (
       select e.ctid
         from public.journal_entries e
         join public.profiles p on p.user_id = e.user_id
        where p.transcript_retention_days is not null
          and e.created_at < now() - make_interval(days => p.transcript_retention_days)
        limit p_batch);
    get diagnostics v_n = row_count;
    v_entries := v_entries + v_n;
    exit when v_n < p_batch;
  end loop;

  return jsonb_build_object('turns', v_turns, 'entries', v_entries);
end;
$$;

revoke all on function public.forget_old_transcripts(integer) from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- Schedule: daily at 03:15 UTC. Idempotent: drop any earlier job first.
-- ────────────────────────────────────────────────────────────
create extension if not exists pg_cron;

select cron.unschedule(jobid) from cron.job where jobname = 'forget-old-transcripts';
select cron.schedule('forget-old-transcripts', '15 3 * * *',
                     'select public.forget_old_transcripts()');
