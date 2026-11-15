-- pgTAP: Phase 2 (I2). forgotten_marker() tells a device whether the account
-- has forgotten anyone since it last looked: the count and the newest
-- created_at of the caller's 'forgotten' suppressions, and nothing else.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(11);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into public.entity_suppressions (user_id, entity_hash, kind, created_at) values
  ('11111111-1111-1111-1111-111111111111', 'h-a1', 'forgotten', '2026-11-10 10:00+00'),
  ('11111111-1111-1111-1111-111111111111', 'h-a2', 'forgotten', '2026-11-11 10:00+00'),
  ('11111111-1111-1111-1111-111111111111', 'h-a3', 'removed',   '2026-11-12 10:00+00'),
  ('22222222-2222-2222-2222-222222222222', 'h-b1', 'forgotten', '2026-11-12 11:00+00');

set local role anon;
select throws_ok($$ select * from public.forgotten_marker() $$, '42501', null,
  'anon cannot call it');

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is((select forgotten_count from public.forgotten_marker()), 2::bigint,
  'counts only the caller''s forgotten rows (not removed, not B''s)');
select is((select latest_at from public.forgotten_marker()),
  '2026-11-11 10:00+00'::timestamptz, 'latest is the newest forgotten row');

-- a person forgotten (here, a removal turned into a forget) moves the marker
reset role;
update public.entity_suppressions set kind = 'forgotten'
  where entity_hash = 'h-a3';
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select is((select forgotten_count from public.forgotten_marker()), 3::bigint,
  'a removal turned into a forget raises the count');

-- B sees only B
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select is((select forgotten_count from public.forgotten_marker()), 1::bigint,
  'B sees B''s count only');
select is((select latest_at from public.forgotten_marker()),
  '2026-11-12 11:00+00'::timestamptz, 'and B''s latest only');

-- no forgotten rows: zero and null, never an error
reset role;
delete from public.entity_suppressions where user_id = '22222222-2222-2222-2222-222222222222';
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select is((select forgotten_count from public.forgotten_marker()), 0::bigint, 'zero when nothing is forgotten');
select is((select latest_at from public.forgotten_marker()), null::timestamptz, 'no latest when nothing is forgotten');

-- it returns no hash and no slug: only two columns, a count and a time
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'forgotten_marker' and p.prosecdef),
  1, 'it is SECURITY DEFINER');
select is(
  (select array_agg(a order by a) from unnest(
     (select proargnames from pg_proc where proname = 'forgotten_marker' and pronamespace = 'public'::regnamespace)) a
    where a is not null),
  array['forgotten_count','latest_at']::text[], 'it exposes a count and a time, no names or hashes');
reset role;
select ok(not has_function_privilege('anon', 'public.forgotten_marker()', 'execute'),
  'anon has no execute privilege');

select * from finish();
rollback;
