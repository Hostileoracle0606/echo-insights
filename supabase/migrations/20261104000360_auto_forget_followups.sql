-- Auto-forget follow-ups (LM-51 fix round 1).
--
-- 1. notebooks.transcript_forgotten_at: set when the sweep deletes turns or
--    entries from a notebook. close-session reads it and will not write a
--    card or brief from the turns that survive, since that would replace the
--    full card with a partial one ("Cards … stay").
-- 2. profiles.transcript_retention_offered_at: the one-time offer is
--    remembered on the account, not the device. Set only through
--    mark_transcript_retention_offered().

alter table public.notebooks
  add column transcript_forgotten_at timestamptz;

comment on column public.notebooks.transcript_forgotten_at is
  'Set by forget_old_transcripts when it removed turns or entries; close-session then keeps the existing card and brief.';

alter table public.profiles
  add column transcript_retention_offered_at timestamptz;

create or replace function public.mark_transcript_retention_offered()
returns void
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
  insert into public.profiles (user_id, transcript_retention_offered_at)
    values (v_uid, now())
    on conflict (user_id)
    do update set transcript_retention_offered_at =
      coalesce(public.profiles.transcript_retention_offered_at, excluded.transcript_retention_offered_at);
end;
$$;

revoke all on function public.mark_transcript_retention_offered() from public, anon;
grant execute on function public.mark_transcript_retention_offered() to authenticated;

-- The sweep now also marks the notebooks it deleted from.
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
    with gone as (
      delete from public.conversation_turns
       where ctid in (
         select t.ctid
           from public.conversation_turns t
           join public.profiles p on p.user_id = t.user_id
          where p.transcript_retention_days is not null
            and t.created_at < now() - make_interval(days => p.transcript_retention_days)
          limit p_batch)
      returning notebook_id
    ), marked as (
      update public.notebooks n
         set transcript_forgotten_at = coalesce(n.transcript_forgotten_at, now())
       where n.id in (select notebook_id from gone)
      returning 1
    )
    select count(*) into v_n from gone;
    v_turns := v_turns + v_n;
    exit when v_n < p_batch;
  end loop;

  loop
    with gone as (
      delete from public.journal_entries
       where ctid in (
         select e.ctid
           from public.journal_entries e
           join public.profiles p on p.user_id = e.user_id
          where p.transcript_retention_days is not null
            and e.created_at < now() - make_interval(days => p.transcript_retention_days)
          limit p_batch)
      returning notebook_id
    ), marked as (
      update public.notebooks n
         set transcript_forgotten_at = coalesce(n.transcript_forgotten_at, now())
       where n.id in (select notebook_id from gone)
      returning 1
    )
    select count(*) into v_n from gone;
    v_entries := v_entries + v_n;
    exit when v_n < p_batch;
  end loop;

  return jsonb_build_object('turns', v_turns, 'entries', v_entries);
end;
$$;

revoke all on function public.forget_old_transcripts(integer) from public, anon, authenticated;
