-- pgTAP tests for the session state record (EC-04): conversation_state.
-- Run: supabase test db   (or scripts/staging-db-test.py on staging)
--
-- One short-lived row per conversation (notebook): open threads, paused
-- topics, commitments, register, covered names. Owner only; written through
-- RPCs; deleted when the conversation ends or the notebook goes.
create extension if not exists pgtap;

begin;
select plan(14);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, started_at) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'A', now()),
  ('44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', 'B', now());

select has_table('public', 'conversation_state', 'conversation_state exists');

set local role anon;
select throws_ok($$ select public.save_conversation_state('33333333-3333-3333-3333-333333333333', '{}'::jsonb) $$,
  '42501', null, 'anon cannot save');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select is(public.get_conversation_state('33333333-3333-3333-3333-333333333333'), null::jsonb,
  'no state yet reads as null');
select lives_ok($$ select public.save_conversation_state('33333333-3333-3333-3333-333333333333',
  '{"openThreads": ["How are you feeling about the move?"], "register": "stressed"}'::jsonb) $$,
  'the owner saves the state');
select is(public.get_conversation_state('33333333-3333-3333-3333-333333333333') -> 'openThreads' ->> 0,
  'How are you feeling about the move?', 'and reads it back');
select lives_ok($$ select public.save_conversation_state('33333333-3333-3333-3333-333333333333',
  '{"openThreads": [], "register": "upbeat"}'::jsonb) $$, 'a later save replaces it');
select is(public.get_conversation_state('33333333-3333-3333-3333-333333333333') ->> 'register', 'upbeat',
  'one row per conversation, the latest wins');
select is((select count(*)::int from public.conversation_state), 1, 'still one row');

select throws_ok($$ select public.save_conversation_state('33333333-3333-3333-3333-333333333333', '[]'::jsonb) $$,
  '22023', null, 'the state must be an object');
select throws_ok(format($$ select public.save_conversation_state('33333333-3333-3333-3333-333333333333', %L::jsonb) $$,
  jsonb_build_object('covered', array[repeat('x', 9000)])::text), '22023', null, 'the state is size-capped');
select throws_ok($$ select public.save_conversation_state('44444444-4444-4444-4444-444444444444', '{}'::jsonb) $$,
  '22023', null, 'no saving into someone else''s notebook');

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(public.get_conversation_state('33333333-3333-3333-3333-333333333333'), null::jsonb,
  'another user reads nothing');

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(public.clear_conversation_state('33333333-3333-3333-3333-333333333333'), true,
  'the conversation ends: its state is deleted');
reset role;

delete from public.notebooks where id = '33333333-3333-3333-3333-333333333333';
select is((select count(*)::int from public.conversation_state), 0, 'and nothing is left');

select * from finish();
rollback;
