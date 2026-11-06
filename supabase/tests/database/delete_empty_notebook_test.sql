-- pgTAP tests for delete_empty_notebook (LM-50). Run: supabase test db
--
-- The server alone decides emptiness: only the owner's notebook with no
-- content of any kind is deleted; every other case changes nothing.
create extension if not exists pgtap;

begin;
select plan(25);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

-- (N9 holds an entity, N10 a runtime session.)
-- A owns: N1 empty, N2 with a turn, N3 with an entry, N4 with a card,
-- N5 committed (revision 2), N6 named by the user, N8 empty (second call).
-- B owns N7 (empty).
insert into public.notebooks (id, user_id, title, title_source, started_at, revision) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 0),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 0),
  ('a1111111-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 0),
  ('a1111111-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 0),
  ('a1111111-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 2),
  ('a1111111-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'Mine', 'user', now(), 0),
  ('b2222222-0000-0000-0000-000000000007', '22222222-2222-2222-2222-222222222222', 'Untitled', 'auto', now(), 0),
  ('a1111111-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 0),
  ('a1111111-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 0);
-- N11 had a conversation auto-forget swept away (LM-51): no rows, revision 0.
insert into public.notebooks (id, user_id, title, title_source, started_at, revision, transcript_forgotten_at) values
  ('a1111111-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 0, now());

insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at) values
  ('a1111111-0000-0000-0000-000000000002', 't1', '11111111-1111-1111-1111-111111111111', 'user', 'hello', now());
insert into public.journal_entries (id, user_id, notebook_id, text, created_at, entity_ids) values
  ('e0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'a1111111-0000-0000-0000-000000000003', 'Priya said hi.', now(), array[]::text[]);
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('a1111111-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'just_talk', 0, '{}'::jsonb);

insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen) values
  ('maya', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000009', 'Maya', 'person', now(), now());
insert into public.conversation_runtime_sessions (id, notebook_id, user_id, device_id, mode) values
  ('c0000000-0000-0000-0000-000000000010', 'a1111111-0000-0000-0000-000000000010',
   '11111111-1111-1111-1111-111111111111', 'd0000000-0000-0000-0000-000000000001', 'granular');

-- anon is refused
set local role anon;
select throws_ok(
  $$ select public.delete_empty_notebook('a1111111-0000-0000-0000-000000000001') $$,
  '42501', null, 'anon cannot call delete_empty_notebook');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000001'),
  '{"deleted": true}'::jsonb, 'the owner deletes an empty notebook');
select is((select count(*) from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  0::bigint, 'the empty notebook is gone');
select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000001'),
  '{"deleted": false}'::jsonb, 'deleting it again reports false');

select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000002'),
  '{"deleted": false}'::jsonb, 'a notebook with a turn is kept');
select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000003'),
  '{"deleted": false}'::jsonb, 'a notebook with an entry is kept');
select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000004'),
  '{"deleted": false}'::jsonb, 'a notebook with a card is kept');
select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000005'),
  '{"deleted": false}'::jsonb, 'a committed notebook (revision > 0) is kept');
select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000006'),
  '{"deleted": false}'::jsonb, 'a notebook the user named is kept');

select is(public.delete_empty_notebook('b2222222-0000-0000-0000-000000000007'),
  '{"deleted": false}'::jsonb, 'another user''s empty notebook is refused');
select is(public.delete_empty_notebook('99999999-9999-9999-9999-999999999999'),
  '{"deleted": false}'::jsonb, 'a missing id returns false');

select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000009'),
  '{"deleted": false}'::jsonb, 'a notebook with an entity is kept');
select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000010'),
  '{"deleted": false}'::jsonb, 'a notebook with a runtime session is kept');

reset role;
select is((select count(*) from public.entities), 1::bigint, 'content untouched: entities');
select is((select count(*) from public.conversation_runtime_sessions), 1::bigint,
  'content untouched: runtime sessions');
select is((select count(*) from public.notebooks
            where id in ('a1111111-0000-0000-0000-000000000002',
                         'a1111111-0000-0000-0000-000000000003',
                         'a1111111-0000-0000-0000-000000000004',
                         'a1111111-0000-0000-0000-000000000005',
                         'a1111111-0000-0000-0000-000000000006',
                         'a1111111-0000-0000-0000-000000000009',
                         'a1111111-0000-0000-0000-000000000010',
                         'b2222222-0000-0000-0000-000000000007')),
  8::bigint, 'every refused case left its notebook in place');
select is((select count(*) from public.conversation_turns), 1::bigint, 'content untouched: turns');
select is((select count(*) from public.session_cards), 1::bigint, 'content untouched: cards');

-- no signed-in user at all
set local role authenticated;
set local request.jwt.claim.sub = '';
select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000006'),
  '{"deleted": false}'::jsonb, 'without a user nothing is deleted');
reset role;

-- A notebook auto-forget emptied held a real conversation.
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(public.delete_empty_notebook('a1111111-0000-0000-0000-000000000011'),
  '{"deleted": false}'::jsonb, 'a notebook emptied by auto-forget is kept');
reset role;
select is((select count(*) from public.notebooks where id = 'a1111111-0000-0000-0000-000000000011'),
  1::bigint, 'and it is still there');

select ok(not has_function_privilege('anon', 'public.delete_empty_notebook(uuid)', 'execute'),
  'anon has no execute grant');
select ok(has_function_privilege('authenticated', 'public.delete_empty_notebook(uuid)', 'execute'),
  'authenticated has execute');

-- A new table with a foreign key to notebooks must be added to the function's
-- content checks (and to this list), or this test fails.
-- conversation_runtime_inbox reaches notebooks only through its session.
select is(
  (select coalesce(array_agg(distinct c.conrelid::regclass::text order by c.conrelid::regclass::text), '{}')
     from pg_constraint c
    where c.contype = 'f' and c.confrelid = 'public.notebooks'::regclass),
  array[
    'asked_questions', 'conversation_runtime_sessions', 'conversation_turns',
    'entities', 'entity_embeddings', 'follow_ups', 'journal_entries',
    'notebook_commit_requests', 'relations', 'session_briefs', 'session_cards'
  ],
  'every table with a foreign key to notebooks is checked by delete_empty_notebook');

-- A new notebooks column can be a trace of earlier content too (as
-- transcript_forgotten_at was). Decide, in the function, and list it here.
select is(
  (select array_agg(a.attname::text order by a.attname::text) from pg_attribute a
    where a.attrelid = 'public.notebooks'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'archived_at', 'conversation_mode', 'created_at', 'duration_seconds', 'ended_at',
    'entity_count', 'id', 'mode_context', 'revision', 'started_at', 'summary', 'title',
    'title_source', 'transcript_forgotten_at', 'updated_at', 'user_id'
  ],
  'every notebooks column has been considered by delete_empty_notebook');

select * from finish();
rollback;
