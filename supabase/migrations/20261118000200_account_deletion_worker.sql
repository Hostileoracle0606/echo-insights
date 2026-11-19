-- Account deletion queue: the worker, its cron job, and the audit-log purge.
--
-- process_account_deletions() deletes every user whose open request is older
-- than p_delay (5 minutes: the app's retry after a lost reply still finds a
-- valid user), at most p_limit requests per run, oldest first.
--   * FOR UPDATE SKIP LOCKED: two overlapping runs never take the same row.
--   * One subtransaction per user: the delete from auth.users (which cascades
--     to every user-owned row and fires on_auth_user_deleted) and the
--     completion mark commit together or not at all. An error for one user
--     is recorded (attempts + 1, last_error = SQLSTATE, never the message)
--     and the loop goes on to the next user; the next tick retries.
--   * Idempotent: a user already gone deletes nothing and is still marked
--     completed; completed rows are never looked at again.
-- Returns the number of request rows marked completed in this run (all open
-- requests of a deleted user are completed together).

create or replace function public.process_account_deletions(
  p_delay interval default interval '5 minutes',
  p_limit int default 20
) returns int
language plpgsql security definer set search_path = '' as $$
declare
  r      record;
  v_seen uuid[] := '{}';
  v_n    int;
  v_done int := 0;
begin
  for r in
    select q.user_id, q.request_id
      from public.account_deletion_requests q
     where q.completed_at is null
       and q.requested_at <= now() - p_delay
     order by q.requested_at, q.user_id, q.request_id
     limit greatest(p_limit, 0)
       for update skip locked
  loop
    -- a user with several due requests is handled once
    continue when r.user_id = any(v_seen);
    v_seen := v_seen || r.user_id;

    begin
      delete from auth.users where id = r.user_id;

      update public.account_deletion_requests
         set completed_at = now(),
             attempts     = attempts + 1,
             last_error   = null
       where user_id = r.user_id
         and completed_at is null;
      get diagnostics v_n = row_count;
      v_done := v_done + v_n;
    exception when others then
      -- no user id and no message in the warning or the row: SQLSTATE only
      raise warning 'account deletion failed (%), will retry', sqlstate;
      update public.account_deletion_requests
         set attempts   = attempts + 1,
             last_error = sqlstate
       where user_id = r.user_id
         and completed_at is null;
    end;
  end loop;

  return v_done;
end;
$$;

revoke all on function public.process_account_deletions(interval, int) from public, anon, authenticated;

comment on function public.process_account_deletions(interval, int) is
  'Account deletion worker (pg_cron, every minute): deletes users whose request is older than p_delay, marks requests completed, records SQLSTATE on failure. Returns request rows completed.';

-- ── cron: every minute, only where pg_cron exists ──────────────────────────
-- Stacks without pg_cron still migrate; the function can be called by hand.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname = 'process-account-deletions';
    perform cron.schedule('process-account-deletions', '* * * * *',
                          'select public.process_account_deletions()');
  else
    raise notice 'pg_cron not available: process-account-deletions not scheduled';
  end if;
end;
$$;

-- ── audit-log purge in the existing BEFORE DELETE trigger ───────────────────
-- auth.audit_log_entries keeps the user id inside its json payload (actor_id
-- for what the user did, traits.user_id for what was done to them), with no
-- foreign key, so its rows outlive the account. They are purged here, in the
-- same trigger as the rate limits and flow_state, so every deletion path (the
-- worker, a direct delete) runs it.
--
-- BEST-EFFORT, like flow_state: auth.audit_log_entries is GoTrue-owned and the
-- function owner may lack delete on it on the hosted project; a failure raises
-- a warning (no user id) and the account deletion goes on. Everything from
-- 20261117000000_account_deletion_flow_state.sql is kept unchanged.
create or replace function public.purge_deleted_user_rate_limits() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.retrieve_rate_limits
  where scope = 'user:' || old.id::text
     or scope in (
       select 'notebook:' || n.id::text
       from public.notebooks n
       where n.user_id = old.id
     );

  begin
    delete from auth.flow_state where user_id = old.id;
  exception when others then
    raise warning 'purge of auth.flow_state skipped: % (%)', sqlerrm, sqlstate;
  end;

  begin
    delete from auth.audit_log_entries
     where payload->>'actor_id' = old.id::text
        or payload->'traits'->>'user_id' = old.id::text;
  exception when others then
    raise warning 'purge of auth.audit_log_entries skipped (%)', sqlstate;
  end;

  return old;
end;
$$;

revoke all on function public.purge_deleted_user_rate_limits() from public, anon, authenticated;

comment on function public.purge_deleted_user_rate_limits() is
  'BEFORE DELETE on auth.users: purges retrieve_rate_limits (strict), auth.flow_state and auth.audit_log_entries (both best-effort).';
