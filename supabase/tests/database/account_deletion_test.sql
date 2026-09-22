-- pgTAP tests for account deletion: deleting the auth user (what
-- auth.admin.deleteUser does in the delete-account edge function) must leave
-- no row belonging to that user in any table, and must not touch anyone else.
-- Run: supabase test db
--
-- Everything happens inside one transaction that is rolled back at the end.
create extension if not exists pgtap;

begin;
select plan(26);

-- ── fixtures: user A (deleted) and user B (bystander), a notebook each ─────
insert into auth.users (id) values
  ('aaaaaaaa-1111-1111-1111-111111111111'),
  ('bbbbbbbb-2222-2222-2222-222222222222');

insert into public.notebooks (id, user_id, title, started_at) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'aaaaaaaa-1111-1111-1111-111111111111', 'A', now()),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'bbbbbbbb-2222-2222-2222-222222222222', 'B', now());

-- One row per table for each user.
insert into public.journal_entries (user_id, notebook_id, text, created_at)
select u, n, 'verbatim transcript', now() from (values
  ('aaaaaaaa-1111-1111-1111-111111111111'::uuid, 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid),
  ('bbbbbbbb-2222-2222-2222-222222222222'::uuid, 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid)) v(u, n);

insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen)
select 'maya', u, n, 'Maya', 'person', now(), now() from (values
  ('aaaaaaaa-1111-1111-1111-111111111111'::uuid, 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid),
  ('bbbbbbbb-2222-2222-2222-222222222222'::uuid, 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid)) v(u, n);

insert into public.relations (id, user_id, notebook_id, source_id, target_id, label)
select 'maya__knows__maya', u, n, 'maya', 'maya', 'knows' from (values
  ('aaaaaaaa-1111-1111-1111-111111111111'::uuid, 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid),
  ('bbbbbbbb-2222-2222-2222-222222222222'::uuid, 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid)) v(u, n);

insert into public.follow_ups (user_id, notebook_id, question)
select u, n, 'How was it?' from (values
  ('aaaaaaaa-1111-1111-1111-111111111111'::uuid, 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid),
  ('bbbbbbbb-2222-2222-2222-222222222222'::uuid, 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid)) v(u, n);

insert into public.asked_questions (user_id, notebook_id, question)
select u, n, 'How was it?' from (values
  ('aaaaaaaa-1111-1111-1111-111111111111'::uuid, 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid),
  ('bbbbbbbb-2222-2222-2222-222222222222'::uuid, 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid)) v(u, n);

insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
select n, 'maya', u, array_fill(0.1::real, array[384])::vector, 'test', 'h' from (values
  ('aaaaaaaa-1111-1111-1111-111111111111'::uuid, 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid),
  ('bbbbbbbb-2222-2222-2222-222222222222'::uuid, 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid)) v(u, n);

insert into public.notebook_commit_requests (notebook_id, request_id, request_hash, result)
select n, gen_random_uuid(), 'h', '{}'::jsonb from (values
  ('aaaaaaaa-0000-0000-0000-00000000000a'::uuid),
  ('bbbbbbbb-0000-0000-0000-00000000000b'::uuid)) v(n);

insert into public.conversation_runtime_sessions (id, notebook_id, user_id, device_id, mode) values
  ('aaaaaaaa-5555-5555-5555-555555555555', 'aaaaaaaa-0000-0000-0000-00000000000a', 'aaaaaaaa-1111-1111-1111-111111111111', gen_random_uuid(), 'wiki'),
  ('bbbbbbbb-5555-5555-5555-555555555555', 'bbbbbbbb-0000-0000-0000-00000000000b', 'bbbbbbbb-2222-2222-2222-222222222222', gen_random_uuid(), 'wiki');

insert into public.conversation_runtime_inbox (session_id, sequence, event_id, observation) values
  ('aaaaaaaa-5555-5555-5555-555555555555', 1, gen_random_uuid(), '{}'::jsonb),
  ('bbbbbbbb-5555-5555-5555-555555555555', 1, gen_random_uuid(), '{}'::jsonb);

-- Rate-limit counters, as bump_retrieve_rate writes them.
insert into public.retrieve_rate_limits (scope, window_start, count) values
  ('user:aaaaaaaa-1111-1111-1111-111111111111', now(), 1),
  ('notebook:aaaaaaaa-0000-0000-0000-00000000000a', now(), 1),
  ('user:bbbbbbbb-2222-2222-2222-222222222222', now(), 1),
  ('notebook:bbbbbbbb-0000-0000-0000-00000000000b', now(), 1);

-- ── sanity: fixtures exist for A before deletion ───────────────────────────
select is((select count(*)::int from public.profiles where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 1, 'before: A has a profile (on_auth_user_created)');
select is((select count(*)::int from public.journal_entries where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 1, 'before: A has a journal entry');
select is((select count(*)::int from public.retrieve_rate_limits where scope like '%aaaaaaaa-%'), 2, 'before: A has rate-limit counters');

-- ── delete user A ─────────────────────────────────────────────────────────
delete from auth.users where id = 'aaaaaaaa-1111-1111-1111-111111111111';

-- ── every row for A is gone ────────────────────────────────────────────────
select is((select count(*)::int from auth.users where id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: auth user gone');
select is((select count(*)::int from public.profiles where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: profiles gone');
select is((select count(*)::int from public.notebooks where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: notebooks gone');
select is((select count(*)::int from public.journal_entries where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: journal_entries gone');
select is((select count(*)::int from public.entities where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: entities gone');
select is((select count(*)::int from public.relations where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: relations gone');
select is((select count(*)::int from public.follow_ups where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: follow_ups gone');
select is((select count(*)::int from public.asked_questions where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: asked_questions gone');
select is((select count(*)::int from public.entity_embeddings where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: entity_embeddings gone');
select is((select count(*)::int from public.notebook_commit_requests where notebook_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 0, 'A: notebook_commit_requests gone');
select is((select count(*)::int from public.conversation_runtime_sessions where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'), 0, 'A: conversation_runtime_sessions gone');
select is((select count(*)::int from public.conversation_runtime_inbox where session_id = 'aaaaaaaa-5555-5555-5555-555555555555'), 0, 'A: conversation_runtime_inbox gone');
select is((select count(*)::int from public.retrieve_rate_limits where scope like '%aaaaaaaa-%'), 0, 'A: retrieve_rate_limits counters gone');

-- ── B is untouched ─────────────────────────────────────────────────────────
select is((select count(*)::int from public.profiles where user_id = 'bbbbbbbb-2222-2222-2222-222222222222'), 1, 'B: profile intact');
select is((select count(*)::int from public.notebooks where user_id = 'bbbbbbbb-2222-2222-2222-222222222222'), 1, 'B: notebook intact');
select is((select count(*)::int from public.journal_entries where user_id = 'bbbbbbbb-2222-2222-2222-222222222222'), 1, 'B: journal entry intact');
select is((select count(*)::int from public.entities where user_id = 'bbbbbbbb-2222-2222-2222-222222222222'), 1, 'B: entity intact');
select is((select count(*)::int from public.relations where user_id = 'bbbbbbbb-2222-2222-2222-222222222222'), 1, 'B: relation intact');
select is((select count(*)::int from public.entity_embeddings where user_id = 'bbbbbbbb-2222-2222-2222-222222222222'), 1, 'B: embedding intact');
select is((select count(*)::int from public.conversation_runtime_inbox where session_id = 'bbbbbbbb-5555-5555-5555-555555555555'), 1, 'B: runtime inbox intact');
select is((select count(*)::int from public.retrieve_rate_limits where scope like '%bbbbbbbb-%'), 2, 'B: rate-limit counters intact');

-- ── the purge function is not callable by clients ─────────────────────────
select ok(not has_function_privilege('authenticated', 'public.purge_deleted_user_rate_limits()', 'execute'), 'purge function: not executable by authenticated');
select ok(not has_function_privilege('anon', 'public.purge_deleted_user_rate_limits()', 'execute'), 'purge function: not executable by anon');

select * from finish();
rollback;
