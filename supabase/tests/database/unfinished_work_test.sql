-- pgTAP: LM-103 - get_unfinished_work: the server's list of text steps the
-- phone should finish at launch (cards, brief, vectors, erase batches).
-- Ids and numbers only; owner-scoped; each list bounded at 50, newest first.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(23);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333'),
  ('44444444-4444-4444-4444-444444444444');

-- User 1, newest first: A, B, C, D (eligible shapes) then the excluded ones.
insert into public.notebooks (id, user_id, title, started_at, revision, conversation_mode, transcript_forgotten_at) values
  ('a1111111-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'A', now() - interval '1 hour',  3, 'just_talk', null),
  ('a1111111-0000-0000-0000-00000000000b', '11111111-1111-1111-1111-111111111111', 'B', now() - interval '2 hours', 2, 'just_talk', null),
  ('a1111111-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', 'C', now() - interval '3 hours', 2, 'just_talk', null),
  ('a1111111-0000-0000-0000-00000000000d', '11111111-1111-1111-1111-111111111111', 'D', now() - interval '4 hours', 1, 'just_talk', null),
  ('a1111111-0000-0000-0000-00000000000e', '11111111-1111-1111-1111-111111111111', 'E', now() - interval '5 hours', 0, 'just_talk', null),
  ('a1111111-0000-0000-0000-00000000000f', '11111111-1111-1111-1111-111111111111', 'F', now() - interval '6 hours', 2, 'just_talk', null),
  ('a1111111-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111', 'G', now() - interval '7 hours', 2, 'weekly_debrief', null),
  ('a1111111-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111', 'H', now() - interval '8 hours', 2, 'just_talk', now()),
  ('b2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'U2', now(), 2, 'just_talk', null);

insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen)
  select 'ent-' || s.suffix, s.uid, s.nb, 'Name ' || s.suffix, 'person', null, '{}', null, 1, now(), now()
  from (values
    ('a1', '11111111-1111-1111-1111-111111111111'::uuid, 'a1111111-0000-0000-0000-00000000000a'::uuid),
    ('a2', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-00000000000a'),
    ('c1', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-00000000000c'),
    ('d1', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-00000000000d'),
    ('g1', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000010'),
    ('h1', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000011'),
    ('u2', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001')
  ) as s(suffix, uid, nb);

-- B has a turn and no entities.
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at) values
  ('a1111111-0000-0000-0000-00000000000b', 't1', '11111111-1111-1111-1111-111111111111', 'user', 'hello', now());

-- C is fully embedded; A has one of two; D has none.
insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash) values
  ('a1111111-0000-0000-0000-00000000000c', 'ent-c1', '11111111-1111-1111-1111-111111111111', array_fill(0, array[384])::vector, 'm', 'h'),
  ('a1111111-0000-0000-0000-00000000000a', 'ent-a1', '11111111-1111-1111-1111-111111111111', array_fill(0, array[384])::vector, 'm', 'h');

-- Cards: B old (rev 1 of 2), C current final, D a draft at its revision.
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card, is_draft) values
  ('a1111111-0000-0000-0000-00000000000b', '11111111-1111-1111-1111-111111111111', 'just_talk', 1, '{}', false),
  ('a1111111-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', 'just_talk', 2, '{}', false),
  ('a1111111-0000-0000-0000-00000000000d', '11111111-1111-1111-1111-111111111111', 'just_talk', 1, '{}', true);

-- User 4: 60 notebooks with no card, one entity each.
insert into public.notebooks (id, user_id, title, started_at, revision, conversation_mode)
  select ('c4444444-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, '44444444-4444-4444-4444-444444444444',
         'N' || g, now() - make_interval(mins => g), 1, 'just_talk'
  from generate_series(1, 60) g;
insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen)
  select 'e' || g, '44444444-4444-4444-4444-444444444444', ('c4444444-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid,
         'N' || g, 'person', null, '{}', null, 1, now(), now()
  from generate_series(1, 60) g;

-- An erase job for user 1 (its own, and one for user 2).
insert into public.forget_erase_jobs (id, user_id, entity_hash, hashes, max_words, cutoff, rewritten, batches_done) values
  ('e1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'hx', '{}', 2, now(), 7, 2),
  ('e2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'hy', '{}', 2, now(), 1, 0);

-- Unauthenticated callers.
set local role anon;
select throws_ok($$select public.get_unfinished_work()$$, '42501', null, 'anon cannot call it');
set local role authenticated;
select throws_ok($$select public.get_unfinished_work()$$, '42501', 'not authenticated', 'no caller, no list');

-- A clean user: every list empty.
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select is(public.get_unfinished_work(),
  '{"cards":[],"briefs":[],"vectors":[],"erase":[],"truncated":false}'::jsonb, 'a clean user has nothing unfinished');

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
create temp table w (j jsonb);
grant all on w to authenticated;
insert into w select public.get_unfinished_work();

select is((select jsonb_array_length(j -> 'cards') from w), 3, 'cards: absent, stale and draft are listed; empty, other-mode, forgotten and finished are not');
select is((select j -> 'cards' -> 0 from w),
  '{"notebookId":"a1111111-0000-0000-0000-00000000000a","revision":3,"cardRevision":null}'::jsonb,
  'newest first: A has no card (cardRevision null)');
select is((select j -> 'cards' -> 1 from w),
  '{"notebookId":"a1111111-0000-0000-0000-00000000000b","revision":2,"cardRevision":1}'::jsonb,
  'B (a turn, no entities) has a card older than its revision');
select is((select j -> 'cards' -> 2 from w),
  '{"notebookId":"a1111111-0000-0000-0000-00000000000d","revision":1,"cardRevision":1,"draft":true}'::jsonb,
  'D has only a draft at its revision: listed, flagged draft');
select is((select count(*)::int from w, jsonb_array_elements(j -> 'cards') c
           where c ->> 'notebookId' in ('a1111111-0000-0000-0000-00000000000c', 'a1111111-0000-0000-0000-00000000000e',
             'a1111111-0000-0000-0000-00000000000f', 'a1111111-0000-0000-0000-000000000010',
             'a1111111-0000-0000-0000-000000000011', 'b2222222-0000-0000-0000-000000000001')), 0,
  'finished, revision 0, empty, other-mode, forgotten and other-user notebooks never appear');

select is((select j -> 'briefs' from w),
  '[{"notebookId":"a1111111-0000-0000-0000-00000000000a","revision":3}]'::jsonb,
  'briefs: only the latest just_talk notebook');

select is((select j -> 'vectors' from w),
  '[{"notebookId":"a1111111-0000-0000-0000-00000000000a","entityCount":2,"missing":1},
    {"notebookId":"a1111111-0000-0000-0000-00000000000d","entityCount":1,"missing":1},
    {"notebookId":"a1111111-0000-0000-0000-000000000010","entityCount":1,"missing":1},
    {"notebookId":"a1111111-0000-0000-0000-000000000011","entityCount":1,"missing":1}]'::jsonb,
  'vectors: notebooks with entities lacking an embedding row (C is complete)');

select is((select j -> 'erase' from w),
  '[{"id":"e1111111-0000-0000-0000-000000000001","rewritten":7,"nextBatch":3}]'::jsonb,
  'erase: the same data as forget_erase_pending, own job only');
select is((select j -> 'erase' from w), public.forget_erase_pending(), 'erase matches forget_erase_pending');
select is((select (j ->> 'truncated')::boolean from w), false, 'a short list is not truncated');

-- No text anywhere in the answer.
select ok((select j::text from w) !~* '(Name |hello|"title"|"summary")', 'the answer carries no text');

-- A brief at the current revision clears the list; an older one does not.
reset role;
insert into public.session_briefs (user_id, source_notebook_id, source_revision, brief, audio, sample_rate) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-00000000000a', 2, '{}', '\x00', 24000);
set local role authenticated;
select is(jsonb_array_length(public.get_unfinished_work() -> 'briefs'), 1, 'a brief from an older revision still counts as unfinished');
reset role;
update public.session_briefs set source_revision = 3;
set local role authenticated;
select is(public.get_unfinished_work() -> 'briefs', '[]'::jsonb, 'a brief at the notebook revision is finished');

-- A final card at the draft's revision clears the draft; the embedding clears vectors.
reset role;
update public.session_cards set is_draft = false
  where notebook_id = 'a1111111-0000-0000-0000-00000000000d';
insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash) values
  ('a1111111-0000-0000-0000-00000000000a', 'ent-a2', '11111111-1111-1111-1111-111111111111', array_fill(0, array[384])::vector, 'm', 'h');
set local role authenticated;
select is((select count(*)::int from jsonb_array_elements(public.get_unfinished_work() -> 'cards') c
           where c ->> 'notebookId' = 'a1111111-0000-0000-0000-00000000000d'), 0, 'a finished card clears the draft entry');
select is((select count(*)::int from jsonb_array_elements(public.get_unfinished_work() -> 'vectors') c
           where c ->> 'notebookId' = 'a1111111-0000-0000-0000-00000000000a'), 0, 'a fully embedded notebook leaves the vectors list');

-- Another user sees only their own.
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(public.get_unfinished_work() -> 'cards' -> 0 ->> 'notebookId', 'b2222222-0000-0000-0000-000000000001', 'user 2 sees only their notebook');
select is(jsonb_array_length(public.get_unfinished_work() -> 'erase'), 1, 'user 2 sees only their erase job');

-- Bounded at 50, newest first, truncated.
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select is(jsonb_array_length(public.get_unfinished_work() -> 'cards'), 50, 'cards are capped at 50');
select is(public.get_unfinished_work() -> 'cards' -> 0 ->> 'notebookId', 'c4444444-0000-0000-0000-000000000001', 'newest notebook first');
select is((public.get_unfinished_work() ->> 'truncated')::boolean, true, 'truncated is set when more than 50 are pending');

select * from finish();
rollback;
