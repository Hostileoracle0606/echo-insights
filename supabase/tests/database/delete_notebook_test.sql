-- pgTAP tests for delete_notebook (LM-48): "Delete this session".
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(22);

-- A has two sessions (N1 is deleted, N2 stays); B is another user.
-- "maya" is in both of A's sessions, "tokyo" only in N1.
insert into auth.users (id) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

insert into public.notebooks (id, user_id, title, started_at) values
  ('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'N1', now()),
  ('a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'N2', now()),
  ('b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B1', now());

insert into public.journal_entries (user_id, notebook_id, text, created_at)
  select user_id, id, 'entry', now() from public.notebooks;
insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen)
  select e, user_id, id, e, 'person', now(), now()
  from public.notebooks, unnest(case title when 'N1' then array['maya', 'tokyo']
                                           when 'N2' then array['maya']
                                           else array['maya'] end) e;
insert into public.relations (id, user_id, notebook_id, source_id, target_id, label)
  select 'r1', user_id, id, 'maya', 'maya', 'knows' from public.notebooks;
insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
  select notebook_id, id, user_id, array_fill(0.0::real, array[384])::vector, 'm', 'h' from public.entities;
insert into public.follow_ups (user_id, notebook_id, question)
  select user_id, id, 'q?' from public.notebooks;
insert into public.asked_questions (user_id, notebook_id, question)
  select user_id, id, 'q?' from public.notebooks;
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at)
  select id, 't1', user_id, 'user', 'hello', now() from public.notebooks;
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card)
  select id, user_id, 'just_talk', 1, '{}'::jsonb from public.notebooks;
insert into public.notebook_commit_requests (notebook_id, request_id, request_hash, result)
  select id, gen_random_uuid(), 'h', '{}'::jsonb from public.notebooks;
insert into public.conversation_runtime_sessions (id, notebook_id, user_id, device_id, mode)
  select gen_random_uuid(), id, user_id, gen_random_uuid(), 'wiki' from public.notebooks;
insert into public.conversation_runtime_inbox (session_id, sequence, event_id, observation)
  select id, 1, gen_random_uuid(), '{}'::jsonb from public.conversation_runtime_sessions;
insert into public.retrieve_rate_limits (scope, window_start, count) values
  ('notebook:a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', now(), 1),
  ('notebook:a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2', now(), 1);
-- A's brief came from N1; B's from B1.
insert into public.session_briefs (user_id, source_notebook_id, source_revision, brief, audio, sample_rate) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', 1, '{}'::jsonb, '\x00', 24000),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1', 1, '{}'::jsonb, '\x00', 24000);

-- ── 1. anon cannot call it ─────────────────────────────────────────────────
set local role anon;
select throws_ok($$ select public.delete_notebook('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1') $$,
  '42501', null, 'anon cannot call delete_notebook');
reset role;

-- ── 2. another user's call changes nothing ─────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
select is(public.delete_notebook('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  '{"deleted": false}'::jsonb, 'a non-owner deletes nothing');
reset role;
select is((select count(*) from public.notebooks), 3::bigint, 'non-owner: all notebooks remain');

-- ── 3. the owner deletes N1 ────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
select is(public.delete_notebook('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  '{"deleted": true}'::jsonb, 'the owner deletes the session');
select is(public.delete_notebook('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  '{"deleted": false}'::jsonb, 'a repeat is a safe no-op');
reset role;

select is((select count(*) from public.notebooks where id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  0::bigint, 'N1 is gone');
select is((select count(*) from public.conversation_turns where notebook_id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  0::bigint, 'turns are gone');
select is((select count(*) from public.journal_entries where notebook_id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  0::bigint, 'journal entries are gone');
select is((select count(*) from public.session_cards where notebook_id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  0::bigint, 'the card is gone');
select is((select count(*) from public.notebook_commit_requests where notebook_id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  0::bigint, 'commit requests are gone');
select is((select count(*) from public.conversation_runtime_sessions where notebook_id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1')
        + (select count(*) from public.conversation_runtime_inbox
            where session_id not in (select id from public.conversation_runtime_sessions)),
  0::bigint, 'runtime session and inbox are gone');
select is((select count(*) from public.follow_ups where notebook_id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1')
        + (select count(*) from public.asked_questions where notebook_id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  0::bigint, 'follow-ups and asked questions are gone');

-- the brief written from N1 goes; B's stays
select is((select count(*) from public.session_briefs where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  0::bigint, 'the brief that came from N1 is gone');
select is((select count(*) from public.session_briefs where user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  1::bigint, 'another user''s brief stays');

-- the graph: tokyo only N1 backed, so it (and its embedding) goes; maya is
-- still backed by N2, so she stays
select is((select count(*) from public.entities where id = 'tokyo' and user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  0::bigint, 'an entity only N1 backed is gone');
select is((select count(*) from public.entity_embeddings where entity_id = 'tokyo' and user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  0::bigint, 'its embedding is gone');
select is((select count(*) from public.entities where id = 'maya' and notebook_id = 'a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2'),
  1::bigint, 'an entity N2 also backs stays');
select is((select count(*) from public.entity_embeddings where entity_id = 'maya' and notebook_id = 'a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2'),
  1::bigint, 'and so does its embedding');
select is((select count(*) from public.relations where notebook_id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'),
  0::bigint, 'N1''s relations are gone');

-- the rate-limit counter is keyed by text, not a foreign key
select is((select count(*) from public.retrieve_rate_limits where scope like 'notebook:a1a1a1a1%'),
  0::bigint, 'the notebook''s rate-limit counter is gone');
select is((select count(*) from public.retrieve_rate_limits where scope like 'notebook:a2a2a2a2%'),
  1::bigint, 'the other session''s counter stays');

-- everything of N2 and B1 is untouched
select is((select count(*) from public.conversation_turns), 2::bigint, 'other sessions'' turns stay');

select * from finish();
rollback;
