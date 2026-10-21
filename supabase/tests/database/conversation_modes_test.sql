-- pgTAP tests for notebooks.conversation_mode / mode_context (LM-01) and the
-- conversationMode field it adds to get_entity_mentions.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(13);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

-- ── 1. defaults ─────────────────────────────────────────────────────────────
-- Inserted the way ensureActiveNotebook and the web app do: no mode given.
insert into public.notebooks (id, user_id, title, started_at) values
  ('a0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Plain', '2026-10-01T09:00:00Z');

select is(
  (select conversation_mode from public.notebooks where id = 'a0000000-0000-0000-0000-000000000001'),
  'just_talk',
  'a notebook inserted without a mode is just_talk');
select is(
  (select mode_context from public.notebooks where id = 'a0000000-0000-0000-0000-000000000001'),
  '{}'::jsonb,
  'a notebook inserted without context has {}');

-- ── 2. the check constraint ─────────────────────────────────────────────────
select lives_ok($$
  insert into public.notebooks (user_id, title, started_at, conversation_mode) values
    ('11111111-1111-1111-1111-111111111111', 'm1', now(), 'weekly_debrief'),
    ('11111111-1111-1111-1111-111111111111', 'm2', now(), 'session_prep'),
    ('11111111-1111-1111-1111-111111111111', 'm3', now(), 'what_landed'),
    ('11111111-1111-1111-1111-111111111111', 'm4', now(), 'first_session'),
    ('11111111-1111-1111-1111-111111111111', 'm5', now(), 'just_talk')
$$, 'all five modes are accepted');
select throws_ok($$
  insert into public.notebooks (user_id, title, started_at, conversation_mode)
  values ('11111111-1111-1111-1111-111111111111', 'ask', now(), 'ask')
$$, '23514', null, 'ask is not a notebook mode');
select throws_ok($$
  insert into public.notebooks (user_id, title, started_at, conversation_mode)
  values ('11111111-1111-1111-1111-111111111111', 'wiki', now(), 'wiki')
$$, '23514', null, 'wiki (an extraction mode) is not a conversation mode');
select throws_ok($$
  insert into public.notebooks (user_id, title, started_at, conversation_mode)
  values ('11111111-1111-1111-1111-111111111111', 'null', now(), null)
$$, '23502', null, 'conversation_mode is not null');

-- ── 3. RLS: the owner sets it, another user can't read it ───────────────────
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select lives_ok($$
  insert into public.notebooks (id, user_id, title, started_at, conversation_mode, mode_context)
  values ('a0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
          'Debrief', '2026-10-23T09:00:00Z', 'weekly_debrief', '{"weekOf": "2026-10-23"}')
$$, 'the owner sets the mode and context on insert');
select is(
  (select array[conversation_mode, mode_context ->> 'weekOf'] from public.notebooks
   where id = 'a0000000-0000-0000-0000-000000000002'),
  array['weekly_debrief', '2026-10-23'],
  'the owner reads back the mode and context');

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(
  (select count(*)::int from public.notebooks where id = 'a0000000-0000-0000-0000-000000000002'),
  0,
  'another user can''t read the notebook or its mode');

-- ── 4. get_entity_mentions carries the notebook's mode ──────────────────────
reset role;
insert into public.journal_entries (id, user_id, notebook_id, text, created_at, entity_ids) values
  ('e0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000001', 'Priya said hi.', '2026-10-01T10:00:00Z', array['priya']),
  ('e0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000002', 'Priya is doing well.', '2026-10-23T10:00:00Z', array['priya']);

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(
  (select array_agg(m ->> 'conversationMode' order by ord)
   from jsonb_array_elements(public.get_entity_mentions('priya') -> 'mentions') with ordinality as t(m, ord)),
  array['weekly_debrief', 'just_talk'],
  'each mention carries its notebook''s conversationMode');

-- ── 5. the replacement kept LM-06's signature and grants ────────────────────
reset role;
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_entity_mentions'),
  1,
  'get_entity_mentions has exactly one overload');
select ok(
  has_function_privilege('authenticated', 'public.get_entity_mentions(text, int, timestamptz)', 'execute'),
  'authenticated can still execute get_entity_mentions');
select ok(
  not has_function_privilege('anon', 'public.get_entity_mentions(text, int, timestamptz)', 'execute'),
  'anon still can''t execute get_entity_mentions');

select * from finish();
rollback;
