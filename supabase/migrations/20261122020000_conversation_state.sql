-- EC-04: the session state record.
--
-- One short-lived row per conversation (notebook): what is open, paused,
-- promised and covered, and the user's register. The app derives it from
-- the finalized turns and saves it after each one (never off the record);
-- every rebuilt Live context includes it; it is deleted when the
-- conversation ends, and with its notebook. Owner only, written through
-- RPCs, capped in size.

create table public.conversation_state (
  notebook_id uuid primary key references public.notebooks(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  state       jsonb not null check (jsonb_typeof(state) = 'object' and pg_column_size(state) <= 8192),
  updated_at  timestamptz not null default now()
);

alter table public.conversation_state enable row level security;

create policy "owner select" on public.conversation_state
  for select using (auth.uid() = user_id);

revoke all on table public.conversation_state from public, anon;
revoke insert, update, delete on table public.conversation_state from authenticated;
grant select on table public.conversation_state to authenticated;

create or replace function public.save_conversation_state(p_notebook_id uuid, p_state jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
begin
  if jsonb_typeof(p_state) is distinct from 'object' or pg_column_size(p_state) > 8192 then
    raise exception 'state must be an object of at most 8 KB' using errcode = '22023';
  end if;
  if not exists (select 1 from public.notebooks n where n.id = p_notebook_id and n.user_id = v_uid) then
    raise exception 'unknown notebook' using errcode = '22023';
  end if;
  insert into public.conversation_state (notebook_id, user_id, state, updated_at)
  values (p_notebook_id, v_uid, p_state, now())
  on conflict (notebook_id) do update
    set state = excluded.state, updated_at = excluded.updated_at
    where public.conversation_state.user_id = v_uid;
end;
$$;

create or replace function public.get_conversation_state(p_notebook_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select s.state from public.conversation_state s
   where s.notebook_id = p_notebook_id and s.user_id = public._memory_fact_uid();
$$;

create or replace function public.clear_conversation_state(p_notebook_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
begin
  delete from public.conversation_state where notebook_id = p_notebook_id and user_id = v_uid;
  return found;
end;
$$;

revoke all on function public.save_conversation_state(uuid, jsonb) from public, anon;
revoke all on function public.get_conversation_state(uuid) from public, anon;
revoke all on function public.clear_conversation_state(uuid) from public, anon;
grant execute on function public.save_conversation_state(uuid, jsonb) to authenticated;
grant execute on function public.get_conversation_state(uuid) to authenticated;
grant execute on function public.clear_conversation_state(uuid) to authenticated;
