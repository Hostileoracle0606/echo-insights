-- pgTAP tests for conversation_turns.input (LM-12): how a user turn reached
-- Lumen, spoken or typed.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(6);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111');
insert into public.notebooks (id, user_id, title, started_at) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'A', now());

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- Written the way the app wrote turns before LM-12: no input given.
insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at)
values ('33333333-3333-3333-3333-333333333333', 't1', 'user', 'I met Maya.', '2026-10-23T12:00:00Z');

select is(
  (select input from public.conversation_turns where turn_id = 't1'),
  'voice',
  'a turn written without input is voice');

select lives_ok($$
  insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at, input)
  values ('33333333-3333-3333-3333-333333333333', 't2', 'user', 'Maya signed off.', '2026-10-23T12:00:04Z', 'typed'),
         ('33333333-3333-3333-3333-333333333333', 't3', 'assistant', 'Good news.', '2026-10-23T12:00:06Z', 'voice')
$$, 'voice and typed are accepted');

select is(
  (select array_agg(input order by spoken_at) from public.conversation_turns
   where notebook_id = '33333333-3333-3333-3333-333333333333'),
  array['voice', 'typed', 'voice'],
  'the owner reads each turn''s input back in spoken order');

select throws_ok($$
  insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at, input)
  values ('33333333-3333-3333-3333-333333333333', 'x', 'user', 'pasted', now(), 'pasted')
$$, '23514', null, 'input is voice or typed');

select throws_ok($$
  insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at, input)
  values ('33333333-3333-3333-3333-333333333333', 'y', 'user', 'null input', now(), null)
$$, '23502', null, 'input is not null');

select throws_ok($$
  update public.conversation_turns set input = 'typed' where turn_id = 't1'
$$, '42501', null, 'input is as immutable as the rest of the turn');

select * from finish();
rollback;
