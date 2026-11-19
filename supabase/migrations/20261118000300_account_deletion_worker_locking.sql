-- Account deletion worker: no deadlock between overlapping runs.
--
-- The first version locked request ROWS (skip locked). A user with two open
-- requests could have one row taken by each of two overlapping runs; each
-- run then deleted the user and updated all of that user's open rows, so
-- each waited on the other's row lock: deadlock (40P01), reproduced with two
-- sessions. Now:
--   * due users are picked without locking any row (one entry per user,
--     ordered by their oldest open request; p_limit counts users);
--   * each user is claimed with a NON-BLOCKING transaction-level advisory
--     lock; if another run holds it, this run skips that user (the other run
--     finishes it, or the next tick retries);
--   * a run therefore only ever touches rows of users it has claimed, and
--     never waits on another run.
-- A user picked from a stale snapshot and already completed by another run is
-- harmless: the delete finds no row, the update finds no open request.
--
-- Also: execute is revoked from service_role (only the cron job, running as
-- the owner, calls it).

create or replace function public.process_account_deletions(
  p_delay interval default interval '5 minutes',
  p_limit int default 20
) returns int
language plpgsql security definer set search_path = '' as $$
declare
  r      record;
  v_n    int;
  v_done int := 0;
begin
  for r in
    select q.user_id
      from public.account_deletion_requests q
     where q.completed_at is null
       and q.requested_at <= now() - p_delay
     group by q.user_id
     order by min(q.requested_at), q.user_id
     limit greatest(p_limit, 0)
  loop
    -- claim the user; another run holding it -> skip, never wait
    continue when not pg_try_advisory_xact_lock(hashtext('process_account_deletions'),
                                                 hashtext(r.user_id::text));

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

revoke all on function public.process_account_deletions(interval, int) from public, anon, authenticated, service_role;

comment on function public.process_account_deletions(interval, int) is
  'Account deletion worker (pg_cron, every minute): deletes up to p_limit users whose oldest open request is older than p_delay, claiming each with a non-blocking advisory lock; marks requests completed, records SQLSTATE on failure. Returns request rows completed.';
