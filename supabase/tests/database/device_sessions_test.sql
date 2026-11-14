-- pgTAP tests for list_my_sessions / revoke_my_session (LM-58).
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(16);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

-- A has two devices (a1 current, a2 other); B has one.
insert into auth.sessions (id, user_id, created_at, updated_at, user_agent, ip) values
  ('a1a1a1a1-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   now() - interval '2 days', now() - interval '1 minute', 'Dart/3.5 (dart:io)', '10.0.0.1'),
  ('a2a2a2a2-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   now() - interval '9 days', now() - interval '3 days', 'Mozilla/5.0 Safari', '10.0.0.2'),
  ('b1b1b1b1-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222',
   now() - interval '1 day', now(), 'Dart/3.5 (dart:io)', '10.0.0.3');
insert into auth.sessions (id, user_id, created_at, updated_at, not_after) values
  ('a3a3a3a3-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   now() - interval '30 days', now() - interval '30 days', now() - interval '1 day');
insert into auth.refresh_tokens (token, user_id, session_id, revoked) values
  ('tok-a2', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', false),
  ('tok-b1', '22222222-2222-2222-2222-222222222222', 'b1b1b1b1-0000-0000-0000-000000000003', false);

-- anon cannot call either
set local role anon;
select throws_ok($$ select * from public.list_my_sessions() $$, '42501', null,
  'anon cannot list sessions');
select throws_ok(
  $$ select public.revoke_my_session('a2a2a2a2-0000-0000-0000-000000000002') $$,
  '42501', null, 'anon cannot revoke');

-- the app roles cannot read auth.sessions directly
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","session_id":"a1a1a1a1-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$ select * from auth.sessions $$, '42501', null,
  'authenticated cannot read auth.sessions directly');

-- A sees only their own live sessions, the current one marked
select is((select count(*)::int from public.list_my_sessions()), 2,
  'A sees two live sessions (not B''s, not the expired one)');
select is(
  (select id from public.list_my_sessions() where is_current),
  'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'the JWT session is marked current');
select is((select count(*)::int from public.list_my_sessions() where is_current), 1,
  'exactly one session is current');
select is(
  (select id from public.list_my_sessions() limit 1),
  'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'most recently active first');

-- revoke: own current session is refused
select is(
  public.revoke_my_session('a1a1a1a1-0000-0000-0000-000000000001'), false,
  'the current session is not revoked here');
-- revoke: B's session is not A's to end
select is(
  public.revoke_my_session('b1b1b1b1-0000-0000-0000-000000000003'), false,
  'another user''s session cannot be revoked');
-- unknown and null ids are harmless
select is(public.revoke_my_session(gen_random_uuid()), false, 'unknown id is false');
select is(public.revoke_my_session(null), false, 'null id is false');
-- A's other device is revoked
select is(
  public.revoke_my_session('a2a2a2a2-0000-0000-0000-000000000002'), true,
  'A revokes their other device');
select is((select count(*)::int from public.list_my_sessions()), 1,
  'the revoked device leaves the list');

reset role;
select is(
  (select count(*)::int from auth.refresh_tokens where session_id = 'a2a2a2a2-0000-0000-0000-000000000002'),
  0, 'its refresh token is gone, so it cannot refresh');
select is(
  (select count(*)::int from auth.sessions where id in
    ('a1a1a1a1-0000-0000-0000-000000000001', 'b1b1b1b1-0000-0000-0000-000000000003')),
  2, 'the current session and B''s session are untouched');
select is(
  (select count(*)::int from auth.refresh_tokens where token = 'tok-b1'),
  1, 'B''s refresh token is untouched');

select * from finish();
rollback;
