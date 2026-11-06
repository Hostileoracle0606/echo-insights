-- pgTAP tests for mark_privacy_screen_seen (LM-53). Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(13);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
-- B has no profile row (a user from before the signup trigger).
delete from public.profiles where user_id = '22222222-2222-2222-2222-222222222222';

-- anon cannot call it
set local role anon;
select throws_ok($$ select public.mark_privacy_screen_seen() $$, '42501', null,
  'anon cannot call mark_privacy_screen_seen');

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select is(
  (select privacy_screen_seen_at from public.profiles
    where user_id = '11111111-1111-1111-1111-111111111111'),
  null, 'unseen at first');

select lives_ok($$ select public.mark_privacy_screen_seen() $$, 'A marks it seen');
select isnt(
  (select privacy_screen_seen_at from public.profiles
    where user_id = '11111111-1111-1111-1111-111111111111'),
  null, 'A has a timestamp');

-- idempotent: the first time stays
reset role;
update public.profiles set privacy_screen_seen_at = '2026-01-01T00:00:00Z'
  where user_id = '11111111-1111-1111-1111-111111111111';
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select lives_ok($$ select public.mark_privacy_screen_seen() $$, 'a second call is fine');
select is(
  (select privacy_screen_seen_at from public.profiles
    where user_id = '11111111-1111-1111-1111-111111111111'),
  '2026-01-01T00:00:00Z'::timestamptz, 'the first time is kept');

-- the column is not directly writable
select throws_ok(
  $$ update public.profiles set privacy_screen_seen_at = null
      where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'cannot update the column directly');
select throws_ok(
  $$ insert into public.profiles (user_id, privacy_screen_seen_at)
     values ('11111111-1111-1111-1111-111111111111', now()) $$,
  '42501', null, 'cannot insert the column directly');
select lives_ok(
  $$ update public.profiles set display_name = 'A'
      where user_id = '11111111-1111-1111-1111-111111111111' $$,
  'display_name is still writable');

-- B (no profile row) gets one, and only B's
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select lives_ok($$ select public.mark_privacy_screen_seen() $$, 'B marks it seen');
select isnt(
  (select privacy_screen_seen_at from public.profiles
    where user_id = '22222222-2222-2222-2222-222222222222'),
  null, 'B has a timestamp');
select is(
  (select count(*)::int from public.profiles), 1,
  'B sees only their own row');
select is(
  (select privacy_screen_seen_at from public.profiles
    where user_id = '11111111-1111-1111-1111-111111111111'),
  null, 'A''s row is invisible to B');

select * from finish();
rollback;
