-- pgTAP tests for the account deletion queue (account_deletion_requests +
-- process_account_deletions). Run: supabase test db
--
-- Users:
--   A  due (two open requests: one old, one young) -> deleted, both completed
--   B  young request only                         -> untouched until due
--   C  due, but its delete raises (forced below)  -> last_error = SQLSTATE, retried
--   D  due, queued after C                        -> still processed
--   E  bystander, no request                      -> untouched
--   G  request for a user that no longer exists   -> completed, no error
create extension if not exists pgtap;

begin;
select plan(48);

create temp table who (name text primary key, uid uuid, nid uuid) on commit drop;
insert into who values
  ('A', 'a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-00000000000a'),
  ('B', 'b0000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-00000000000b'),
  ('C', 'c0000000-0000-0000-0000-00000000000c', 'c1000000-0000-0000-0000-00000000000c'),
  ('D', 'd0000000-0000-0000-0000-00000000000d', 'd1000000-0000-0000-0000-00000000000d'),
  ('E', 'e0000000-0000-0000-0000-00000000000e', 'e1000000-0000-0000-0000-00000000000e'),
  ('G', '90000000-0000-0000-0000-000000000009', null);

create function pg_temp.uid(p text) returns uuid language sql stable as
  $$ select uid from who where name = p $$;

-- ── schema ─────────────────────────────────────────────────────────────────
select has_table('public', 'account_deletion_requests', 'account_deletion_requests exists');
select columns_are('public', 'account_deletion_requests',
  array['user_id', 'request_id', 'requested_at', 'completed_at', 'attempts', 'last_error'],
  'account_deletion_requests holds ids, times, a counter and a SQLSTATE only');
select col_is_pk('public', 'account_deletion_requests', array['user_id', 'request_id'],
  'primary key is (user_id, request_id)');
select is_empty(
  $$ select conname from pg_constraint
      where conrelid = 'public.account_deletion_requests'::regclass and contype = 'f' $$,
  'no foreign key: the request must outlive the user');
select ok((select relrowsecurity from pg_class where oid = 'public.account_deletion_requests'::regclass),
  'RLS is enabled on account_deletion_requests');
select has_index('public', 'account_deletion_requests', 'account_deletion_requests_pending_idx',
  'partial index on pending requests');
select ok((select prosecdef from pg_proc where oid = 'public.process_account_deletions(interval,int)'::regprocedure),
  'process_account_deletions is security definer');
select ok(not has_function_privilege('authenticated', 'public.process_account_deletions(interval,int)', 'execute')
      and not has_function_privilege('anon', 'public.process_account_deletions(interval,int)', 'execute'),
  'app roles cannot run the worker');

-- cron job, only where pg_cron is installed
create function pg_temp.cron_ok() returns boolean language plpgsql as $$
declare v boolean;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    return true;
  end if;
  execute $q$ select exists (select 1 from cron.job
                              where jobname = 'process-account-deletions'
                                and schedule = '* * * * *'
                                and command ilike '%process_account_deletions%') $q$ into v;
  return v;
end $$;
select ok(pg_temp.cron_ok(), 'cron job process-account-deletions runs every minute (when pg_cron is present)');

-- ── seed ───────────────────────────────────────────────────────────────────
insert into auth.users (id) select uid from who where name <> 'G';   -- profiles trigger adds profiles
insert into public.notebooks (id, user_id, title, started_at)
  select nid, uid, 'nb ' || name, now() from who where name <> 'G';
insert into public.journal_entries (user_id, notebook_id, text, created_at)
  select uid, nid, 'entry', now() from who where name <> 'G';
insert into public.retrieve_rate_limits (scope, window_start, count)
  select 'user:' || uid, now(), 1 from who where name <> 'G';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select gen_random_uuid(), uid, now(), now() from who where name <> 'G';
insert into auth.audit_log_entries (id, payload, created_at)
  select gen_random_uuid(),
         json_build_object('actor_id', uid::text, 'actor_username', 'x', 'action', 'login', 'log_type', 'account'),
         now()
    from who where name <> 'G';

insert into public.account_deletion_requests (user_id, request_id, requested_at) values
  (pg_temp.uid('A'), 'a2000000-0000-0000-0000-000000000001', now() - interval '10 minutes'),
  (pg_temp.uid('A'), 'a2000000-0000-0000-0000-000000000002', now() - interval '1 minute'),
  (pg_temp.uid('B'), 'b2000000-0000-0000-0000-000000000001', now() - interval '1 minute'),
  (pg_temp.uid('C'), 'c2000000-0000-0000-0000-000000000001', now() - interval '9 minutes'),
  (pg_temp.uid('D'), 'd2000000-0000-0000-0000-000000000001', now() - interval '8 minutes'),
  (pg_temp.uid('G'), '92000000-0000-0000-0000-000000000001', now() - interval '7 minutes');

-- everything a user has, across the tables seeded above
create function pg_temp.rows_of(p text) returns bigint language sql as $$
  select (select count(*) from auth.users where id = pg_temp.uid(p))
       + (select count(*) from public.profiles where user_id = pg_temp.uid(p))
       + (select count(*) from public.notebooks where user_id = pg_temp.uid(p))
       + (select count(*) from public.journal_entries where user_id = pg_temp.uid(p))
       + (select count(*) from public.retrieve_rate_limits where scope = 'user:' || pg_temp.uid(p))
       + (select count(*) from auth.sessions where user_id = pg_temp.uid(p))
       + (select count(*) from auth.audit_log_entries where payload->>'actor_id' = pg_temp.uid(p)::text)
$$;

select is(pg_temp.rows_of(n), 7::bigint, n || ': seeded in all 7 places')
  from unnest(array['A', 'C', 'D', 'E']) n;

-- ── RLS: an authenticated user sees only their own request rows ────────────
set local role authenticated;
-- (literal ids here: the temp table `who` is not readable by app roles)
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
select is((select count(*) from public.account_deletion_requests), 2::bigint,
  'RLS: A sees exactly two request rows');
select is((select count(*) from public.account_deletion_requests where user_id <> 'a0000000-0000-0000-0000-00000000000a'), 0::bigint,
  'RLS: A sees no one else''s request rows');
select throws_ok(
  $$ insert into public.account_deletion_requests (user_id, request_id)
     values ('a0000000-0000-0000-0000-00000000000a', gen_random_uuid()) $$,
  '42501', null, 'authenticated cannot insert a request');
select throws_ok(
  $$ update public.account_deletion_requests set completed_at = now() $$,
  '42501', null, 'authenticated cannot update a request');
select throws_ok(
  $$ delete from public.account_deletion_requests $$,
  '42501', null, 'authenticated cannot delete a request');
select throws_ok($$ select public.process_account_deletions() $$, '42501', null,
  'authenticated cannot run the worker');
set local role anon;
select throws_ok($$ select count(*) from public.account_deletion_requests $$, '42501', null,
  'anon cannot read requests');
reset role;
select set_config('request.jwt.claims', '', true);

-- ── force one failure: C's delete raises (through the notebook cascade) ────
create function public.tmp_fail_c() returns trigger language plpgsql as $$
begin
  if old.user_id = 'c0000000-0000-0000-0000-00000000000c' then
    raise exception 'forced failure';
  end if;
  return old;
end $$;
create trigger tmp_fail_c before delete on public.notebooks
  for each row execute function public.tmp_fail_c();

-- ── first run ──────────────────────────────────────────────────────────────
-- completes A's two requests, D's and G's = 4; C fails; B is too young.
select is(public.process_account_deletions(), 4, 'first run completes 4 request rows');

select is(pg_temp.rows_of('A'), 0::bigint, 'A: user and every row of theirs are gone');
select is((select count(*) from public.account_deletion_requests
            where user_id = pg_temp.uid('A') and completed_at is not null and last_error is null), 2::bigint,
  'A: both open requests (old and young) are marked completed');
select is((select count(*) from public.account_deletion_requests where user_id = pg_temp.uid('A')), 2::bigint,
  'A: the request rows outlive the user (no FK)');

select is(pg_temp.rows_of('B'), 7::bigint, 'B: a request younger than the delay is not processed');
select ok((select completed_at is null and attempts = 0 from public.account_deletion_requests
            where user_id = pg_temp.uid('B')), 'B: request still open, no attempt');

select is(pg_temp.rows_of('C'), 7::bigint, 'C: failed deletion rolled back, nothing of C removed');
select is((select last_error from public.account_deletion_requests where user_id = pg_temp.uid('C')), 'P0001',
  'C: last_error is the SQLSTATE');
select matches((select last_error from public.account_deletion_requests where user_id = pg_temp.uid('C')),
  '^[0-9A-Z]{5}$', 'C: last_error is a 5-character code, nothing else');
select ok((select completed_at is null and attempts = 1 from public.account_deletion_requests
            where user_id = pg_temp.uid('C')), 'C: still open, attempts = 1');

select is(pg_temp.rows_of('D'), 0::bigint, 'D: processed after C''s failure');
select ok((select completed_at is not null and attempts = 1 and last_error is null
             from public.account_deletion_requests where user_id = pg_temp.uid('D')),
  'D: request completed');

select ok((select completed_at is not null and last_error is null
             from public.account_deletion_requests where user_id = pg_temp.uid('G')),
  'G: user already gone -> request completed, no error');

select is(pg_temp.rows_of('E'), 7::bigint, 'E: a bystander and their rows are untouched');
select is((select count(*) from public.profiles), (select count(*) from auth.users),
  'every remaining user still has a profile');

-- ── second run: harmless ───────────────────────────────────────────────────
select lives_ok($$ select public.process_account_deletions() $$, 'second run raises nothing');
-- (lives_ok ran it once: C failed again; now a third call for the return value)
select is(public.process_account_deletions(), 0, 'another run with only the failing user completes 0');
select ok((select attempts = 3 and last_error = 'P0001' and completed_at is null
             from public.account_deletion_requests where user_id = pg_temp.uid('C')),
  'C: each run retries and counts the attempt');
select is((select count(*) from public.account_deletion_requests where completed_at is not null), 4::bigint,
  'completed rows are not touched again');

-- ── the failure clears: C goes on the next tick ────────────────────────────
drop trigger tmp_fail_c on public.notebooks;
drop function public.tmp_fail_c();
select is(public.process_account_deletions(), 1, 'retry after the failure clears completes C');
select is(pg_temp.rows_of('C'), 0::bigint, 'C: gone');
select ok((select completed_at is not null and attempts = 4 and last_error is null
             from public.account_deletion_requests where user_id = pg_temp.uid('C')),
  'C: completed, last_error cleared');

-- ── p_delay and p_limit ────────────────────────────────────────────────────
select is(public.process_account_deletions(interval '1 hour'), 0, 'a longer delay leaves B alone');
insert into auth.users (id) values ('f0000000-0000-0000-0000-00000000000f');
insert into public.account_deletion_requests (user_id, request_id, requested_at) values
  ('f0000000-0000-0000-0000-00000000000f', gen_random_uuid(), now() - interval '2 minutes');
select is(public.process_account_deletions(interval '30 seconds', 1), 1, 'p_limit caps one run');
select is((select count(*) from public.account_deletion_requests where completed_at is null), 1::bigint,
  'one request is left for the next tick');
select is(public.process_account_deletions(interval '30 seconds'), 1, 'the next tick takes it');
select is((select count(*) from auth.users where id in (pg_temp.uid('B'), 'f0000000-0000-0000-0000-00000000000f')),
  0::bigint, 'B and F are gone once due');
select is(pg_temp.rows_of('E'), 7::bigint, 'E: still untouched at the end');

select * from finish();
rollback;
