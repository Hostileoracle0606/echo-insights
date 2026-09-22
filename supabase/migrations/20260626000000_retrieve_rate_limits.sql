-- Fixed-window rate limiting for the retrieve-memory edge function.
-- Operational state, NOT user data: clients get zero direct access. Rows are
-- keyed by an opaque scope string ('user:<uid>' or 'notebook:<id>') and may be
-- touched only by the SECURITY DEFINER RPC below.
create table public.retrieve_rate_limits (
  scope        text not null,
  window_start timestamptz not null,
  count        int not null default 0,
  primary key (scope, window_start)
);

-- RLS on + no policy = no direct row access for anon/authenticated. The revokes
-- below are belt-and-suspenders against PostgREST exposure.
alter table public.retrieve_rate_limits enable row level security;
revoke all on table public.retrieve_rate_limits from anon, authenticated;

-- Atomically bump the caller's per-user AND per-notebook counters for the
-- current window and report whether BOTH are within their limits.
--
-- SELF-CONTAINED & TAMPER-PROOF — the function takes ONLY p_notebook_id; the
-- window and limits are hardcoded in the DB so a direct RPC caller (the RPC is
-- granted to `authenticated`) cannot widen its own limits. Ownership is verified
-- INSIDE the function, before any counter is touched, so a caller cannot inflate
-- the notebook:<id> counter of a notebook they do not own (cross-notebook
-- griefing). The user:<uid> scope derives from auth.uid(), never a parameter, so
-- it can only ever bump the caller's own user counter.
--
-- SECURITY DEFINER (runs as owner, bypassing RLS) so the caller cannot mutate
-- the counters directly. Fixed search_path is mandatory for DEFINER safety.
-- auth.uid() reads the request JWT claim and works under DEFINER.
create or replace function public.bump_retrieve_rate(p_notebook_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_window_seconds  constant int := 60;
  v_user_limit      constant int := 30;
  v_notebook_limit  constant int := 20;
  v_window timestamptz := to_timestamp(
    floor(extract(epoch from now()) / v_window_seconds) * v_window_seconds
  );
  v_user_count int;
  v_nb_count int;
begin
  if v_uid is null then
    return false;
  end if;

  -- Never bump a counter for a notebook the caller does not own.
  if not exists (
    select 1 from public.notebooks where id = p_notebook_id and user_id = v_uid
  ) then
    return false;
  end if;

  insert into public.retrieve_rate_limits (scope, window_start, count)
    values ('user:' || v_uid::text, v_window, 1)
  on conflict (scope, window_start)
    do update set count = retrieve_rate_limits.count + 1
  returning count into v_user_count;

  insert into public.retrieve_rate_limits (scope, window_start, count)
    values ('notebook:' || p_notebook_id::text, v_window, 1)
  on conflict (scope, window_start)
    do update set count = retrieve_rate_limits.count + 1
  returning count into v_nb_count;

  return v_user_count <= v_user_limit and v_nb_count <= v_notebook_limit;
end;
$$;

-- Execute granted ONLY to authenticated; revoke the default public grant.
revoke all on function public.bump_retrieve_rate(uuid) from public, anon;
grant execute on function public.bump_retrieve_rate(uuid) to authenticated;
