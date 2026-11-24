-- EC-09: backfill facts for journals written before EC-03.
--
-- A script (scripts/backfill-facts.py) runs the same extraction over the
-- user's existing entries, oldest first, and records each entry's facts with
-- record_memory_facts(..., p_replace => true), so a re-run adds nothing. This
-- is its cursor:
--   list_backfill_entries   the next entries after the cursor: the user's own
--                           words only (an entry equal to one of Lumen's turns
--                           is skipped), linked to at least one entity, with
--                           the Forget-redacted text, entities and time, and
--                           whether facts were already extracted from it live
--   advance_memory_backfill moves the cursor past an entry, so a run can stop
--                           anywhere and resume
--   reset_memory_backfill   starts over
-- The cursor row holds no journal content.

create table public.memory_backfill_progress (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  last_created_at timestamptz not null,
  last_entry_id   uuid not null,
  updated_at      timestamptz not null default now()
);

alter table public.memory_backfill_progress enable row level security;
create policy "owner select" on public.memory_backfill_progress
  for select using (auth.uid() = user_id);
revoke all on table public.memory_backfill_progress from public, anon;
revoke insert, update, delete on table public.memory_backfill_progress from authenticated;
grant select on table public.memory_backfill_progress to authenticated;

create or replace function public.list_backfill_entries(p_limit int default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
  v_cursor public.memory_backfill_progress;
begin
  select * into v_cursor from public.memory_backfill_progress where user_id = v_uid;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'entryId', j.id,
             'notebookId', j.notebook_id,
             'text', coalesce(j.context_text, j.text),
             'spokenAt', j.created_at,
             'hasFacts', exists (select 1 from public.memory_facts f where f.source_entry_id = j.id),
             'entities', coalesce((
               select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'type', e.type) order by e.id)
                 from public.entities e
                where e.notebook_id = j.notebook_id and e.id = any (j.entity_ids)
             ), '[]'::jsonb)
           ) order by j.created_at, j.id)
      from (
        select je.* from public.journal_entries je
         where je.user_id = v_uid
           and cardinality(coalesce(je.entity_ids, '{}'::text[])) > 0
           and (v_cursor.user_id is null
                or (je.created_at, je.id) > (v_cursor.last_created_at, v_cursor.last_entry_id))
           and not exists (
             select 1 from public.conversation_turns t
              where t.notebook_id = je.notebook_id and t.speaker = 'assistant' and t.text = je.text
           )
         order by je.created_at, je.id
         limit least(greatest(coalesce(p_limit, 20), 1), 100)
      ) j
  ), '[]'::jsonb);
end;
$$;

create or replace function public.advance_memory_backfill(p_entry_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
  v_at timestamptz;
begin
  select created_at into v_at from public.journal_entries where id = p_entry_id and user_id = v_uid;
  if v_at is null then
    raise exception 'unknown entry' using errcode = '22023';
  end if;
  insert into public.memory_backfill_progress (user_id, last_created_at, last_entry_id, updated_at)
  values (v_uid, v_at, p_entry_id, now())
  on conflict (user_id) do update
    set last_created_at = excluded.last_created_at, last_entry_id = excluded.last_entry_id, updated_at = now();
end;
$$;

create or replace function public.reset_memory_backfill()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.memory_backfill_progress where user_id = public._memory_fact_uid();
end;
$$;

revoke all on function public.list_backfill_entries(int) from public, anon;
revoke all on function public.advance_memory_backfill(uuid) from public, anon;
revoke all on function public.reset_memory_backfill() from public, anon;
grant execute on function public.list_backfill_entries(int) to authenticated;
grant execute on function public.advance_memory_backfill(uuid) to authenticated;
grant execute on function public.reset_memory_backfill() to authenticated;
