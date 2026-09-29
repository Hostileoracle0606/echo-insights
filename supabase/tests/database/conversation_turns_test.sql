-- pgTAP tests for conversation_turns (owner-only, immutable, idempotent).
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(9);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, started_at) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'A', now()),
  ('44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', 'B', now());

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select lives_ok($$
  insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at)
  values ('33333333-3333-3333-3333-333333333333', 't1', 'user', 'I met Maya.', '2026-09-28T12:00:00Z'),
         ('33333333-3333-3333-3333-333333333333', 't2', 'assistant', 'How was it?', '2026-09-28T12:00:05Z')
$$, 'the owner writes turns into their notebook (user_id defaults to the caller)');

select is(
  (select user_id::text from public.conversation_turns where turn_id = 't1'),
  '11111111-1111-1111-1111-111111111111',
  'user_id is the caller');

select lives_ok($$
  insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at)
  values ('33333333-3333-3333-3333-333333333333', 't1', 'user', 'I met Maya.', '2026-09-28T12:00:00Z')
  on conflict (notebook_id, turn_id) do nothing
$$, 'a retried write is ignored as a duplicate');

select throws_ok($$
  insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at)
  values ('44444444-4444-4444-4444-444444444444', 'x', 'user', 'not mine', now())
$$, '42501', null, 'no writes into another user''s notebook');

select throws_ok($$
  insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at)
  values ('33333333-3333-3333-3333-333333333333', 'y', '22222222-2222-2222-2222-222222222222', 'user', 'spoofed', now())
$$, '42501', null, 'no writes as another user');

select throws_ok($$
  insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at)
  values ('33333333-3333-3333-3333-333333333333', 'z', 'system', 'bad speaker', now())
$$, '23514', null, 'speaker is user or assistant');

select throws_ok($$
  update public.conversation_turns set text = 'rewritten' where turn_id = 't1'
$$, '42501', null, 'turns are immutable');

select is(
  (select array_agg(turn_id order by spoken_at) from public.conversation_turns
   where notebook_id = '33333333-3333-3333-3333-333333333333'),
  array['t1', 't2'],
  'the owner reads their turns in spoken order');

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(
  (select count(*)::int from public.conversation_turns),
  0,
  'another user sees none of them');

select * from finish();
rollback;
