-- pgTAP tests for export_my_data (LM-52). Run: supabase test db
--
-- The RPC is SECURITY DEFINER, so the point of most checks is the second user:
-- one missing user filter would put B's journal in A's export.
create extension if not exists pgtap;

begin;
select plan(25);

-- ── fixtures (default role, so RLS doesn't apply while seeding) ────────────
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333');

-- A owns N1 and N2 (N2 is empty); B owns N3; C owns nothing.
insert into public.notebooks (id, user_id, title, started_at, summary, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'A first', '2026-10-01T10:00:00Z', 'A summary', 'just_talk'),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'A second', '2026-10-02T10:00:00Z', null, 'weekly_debrief'),
  ('b2222222-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'B secret title', '2026-10-03T10:00:00Z', 'B secret summary', 'just_talk');

insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at, input) values
  ('a1111111-0000-0000-0000-000000000001', 't2', '11111111-1111-1111-1111-111111111111', 'assistant', 'Tell me more.', '2026-10-01T10:00:20Z', 'voice'),
  ('a1111111-0000-0000-0000-000000000001', 't1', '11111111-1111-1111-1111-111111111111', 'user', 'I saw Maya today.', '2026-10-01T10:00:10Z', 'typed'),
  ('b2222222-0000-0000-0000-000000000003', 'bt1', '22222222-2222-2222-2222-222222222222', 'user', 'B secret turn', '2026-10-03T10:00:10Z', 'voice');

insert into public.journal_entries (id, user_id, notebook_id, text, created_at, entity_ids, relation_ids) values
  ('e1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Saw Maya.', '2026-10-01T10:00:11Z', '{maya}', '{r1}'),
  ('e2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'B secret entry', '2026-10-03T10:00:11Z', '{}', '{}');

insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, mentions, first_seen, last_seen, questions) values
  ('maya', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Maya', 'person', 'A friend', '{"k": 1}', 2, '2026-10-01T10:00:00Z', '2026-10-01T10:00:11Z', '{"Where is she moving?"}'),
  ('lisbon', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Lisbon', 'place', null, '{}', 1, '2026-10-01T10:00:00Z', '2026-10-01T10:00:00Z', null),
  ('bsecret', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'B secret entity', 'person', null, '{}', 1, '2026-10-03T10:00:00Z', '2026-10-03T10:00:00Z', null);

insert into public.relations (id, user_id, notebook_id, source_id, target_id, label, superseded_at) values
  ('r1', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'maya', 'lisbon', 'moving_to', null),
  ('br1', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'bsecret', 'bsecret', 'B secret relation', null);

insert into public.follow_ups (user_id, notebook_id, question, reason) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'How is Maya?', 'recent'),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'B secret follow-up', 'x');

insert into public.asked_questions (user_id, notebook_id, question) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Where is Lisbon?'),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'B secret asked');

insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'just_talk', 1, '{"title": "A card"}'),
  ('b2222222-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'just_talk', 1, '{"title": "B secret card"}');

-- Internal rows that must not leak into the export.
insert into public.session_briefs (user_id, source_revision, brief, audio, sample_rate) values
  ('11111111-1111-1111-1111-111111111111', 1, '{"line": "A brief line"}', '\x0102', 24000);

-- ── 1. anon cannot call it ─────────────────────────────────────────────────
set local role anon;
select throws_ok($$ select public.export_my_data() $$, '42501', null,
  'anon cannot call export_my_data');
reset role;

-- ── 2. A's export: shape ───────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

create temp table a_export as select public.export_my_data() as j;
grant select on a_export to authenticated;

select is((select j->>'version' from a_export), '1', 'version is 1');
select ok((select (j->>'exportedAt')::timestamptz is not null from a_export),
  'exportedAt is a timestamp');
select is((select array(select jsonb_object_keys(j) order by 1) from a_export),
  array['exportedAt', 'notebooks', 'version'], 'top level has exactly three keys');
select is((select jsonb_array_length(j->'notebooks') from a_export), 2,
  'both of A''s notebooks, and only those');
select is((select array(select jsonb_object_keys(j->'notebooks'->0) order by 1) from a_export),
  array['archivedAt', 'askedQuestions', 'card', 'conversationMode', 'createdAt',
        'durationSeconds', 'endedAt', 'entities', 'entityCount', 'followUps', 'id',
        'journalEntries', 'modeContext', 'relations', 'startedAt', 'summary',
        'title', 'titleSource', 'turns', 'updatedAt'],
  'a notebook has the documented keys, and no userId or revision');
select is((select j->'notebooks'->0->>'title' from a_export), 'A first',
  'notebooks are oldest first');

-- ── 3. A's export: content ─────────────────────────────────────────────────
select is((select jsonb_path_query_array(j, '$.notebooks[0].turns[*].id') from a_export),
  '["t1", "t2"]'::jsonb, 'turns are in spoken order');
select is((select j->'notebooks'->0->'turns'->0 from a_export),
  '{"id": "t1", "text": "I saw Maya today.", "input": "typed", "speaker": "user", "spokenAt": "2026-10-01T10:00:10+00:00"}'::jsonb,
  'a turn carries id, speaker, text, spokenAt and input');
select is((select j->'notebooks'->0->'journalEntries'->0->'entityIds' from a_export),
  '["maya"]'::jsonb, 'an entry keeps its provenance ids');
select is((select jsonb_array_length(j->'notebooks'->0->'entities') from a_export), 2,
  'entities are an array');
select is((select j->'notebooks'->0->'entities'->1->'questions' from a_export),
  '["Where is she moving?"]'::jsonb, 'entity questions are kept');
select is((select j->'notebooks'->0->'entities'->0->'questions' from a_export),
  'null'::jsonb, 'no questions stays null');
select is((select j->'notebooks'->0->'relations'->0->>'label' from a_export),
  'moving_to', 'relations are exported');
select is((select j->'notebooks'->0->'card' from a_export),
  '{"title": "A card"}'::jsonb, 'the closing card is exported');
select is((select jsonb_array_length(j->'notebooks'->0->'followUps')
                 + jsonb_array_length(j->'notebooks'->0->'askedQuestions') from a_export), 2,
  'follow-ups and asked questions are exported');
select is((select j->'notebooks'->1 -> 'card' from a_export), 'null'::jsonb,
  'a notebook without a card has a null card');
select is((select jsonb_array_length(j->'notebooks'->1->'turns') from a_export), 0,
  'an empty notebook has empty arrays');

-- ── 4. no other user's data; no internal data ──────────────────────────────
select ok((select position('B secret' in j::text) = 0 from a_export),
  'nothing of B''s appears anywhere in A''s export');
select ok((select position('A brief line' in j::text) = 0 and position('audio' in j::text) = 0
           from a_export), 'briefs and audio are not exported');

-- B's notebook id passed by A narrows to nothing.
select is(
  public.export_my_data(array['b2222222-0000-0000-0000-000000000003']::uuid[]),
  (select jsonb_build_object('version', 1, 'exportedAt', public.export_my_data()->'exportedAt',
                             'notebooks', '[]'::jsonb)),
  'asking for another user''s notebook id returns no notebooks');

-- ── 5. narrowing, and a user with nothing ──────────────────────────────────
select is(
  jsonb_array_length(public.export_my_data(array['a1111111-0000-0000-0000-000000000002']::uuid[])->'notebooks'),
  1, 'a notebook-id list narrows the export');

select lives_ok(
  $$ select public.export_my_data((select array_agg(gen_random_uuid()) from generate_series(1, 50))) $$,
  '50 notebook ids is allowed');
select throws_ok(
  $$ select public.export_my_data((select array_agg(gen_random_uuid()) from generate_series(1, 51))) $$,
  '22023', null, 'more than 50 notebook ids is refused');

set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select is(public.export_my_data()->'notebooks', '[]'::jsonb,
  'a user with no notebooks gets an empty list');

select * from finish();
rollback;
