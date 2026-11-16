-- pgTAP: LM-102 - erase batches keyed by (job, batch number).
-- forget_erase_batch runs the existing erase step once per key: the same
-- batch twice gives one rewrite and the same result; a changed batch size
-- under the same key is refused (keyReused); a batch that is not the next
-- one is refused (outOfOrder, with nextBatch). forget_erase_step still works.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(28);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into public.notebooks (id, user_id, title, summary, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N1', 'S', now(), 3, 'just_talk');

insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen) values
  ('maya-chen', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Maya Chen', 'person', null, '{}', null, 1, now(), now());

insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at)
  select 'a1111111-0000-0000-0000-000000000001', 'bulk-' || lpad(g::text, 3, '0'), '11111111-1111-1111-1111-111111111111',
         'user', 'Turn ' || g || ': Maya Chen said hi.', now() - make_interval(secs => 1000 - g)
  from generate_series(1, 250) g;

create temp table job (id uuid);
grant all on job to authenticated;
create temp table res (k text, result jsonb);
grant all on res to authenticated;

set local role anon;
select throws_ok($$select public.forget_erase_batch(gen_random_uuid(), 1, 100)$$, '42501', null, 'anon cannot run a batch');
set local role authenticated;
select throws_ok($$select public.forget_erase_batch(gen_random_uuid(), 1, 100)$$, '42501', null, 'no caller, no batch');
select throws_ok($$select count(*) from public.forget_erase_batches$$, '42501', null,
  'the batch ledger is not readable by clients');

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into job select (public.forget_entity('maya-chen', true) ->> 'eraseJobId')::uuid;

select is((select p ->> 'nextBatch' from jsonb_array_elements(public.forget_erase_pending()) p), '1',
  'pending: a fresh job expects batch 1');

-- Out of order first: batch 2 before batch 1.
select is(public.forget_erase_batch((select id from job), 2, 100),
  '{"status":"rejected","code":"outOfOrder","nextBatch":1}'::jsonb, 'batch 2 before batch 1 is refused with nextBatch');
select is((select count(*)::int from public.conversation_turns where text like '%Maya Chen%'), 250,
  'the refused batch rewrote nothing');

insert into res select 'first', public.forget_erase_batch((select id from job), 1, 100);
select is((select result ->> 'rewritten' from res where k = 'first'), '100', 'batch 1 rewrote 100 rows');
select is((select result ->> 'batchNo' from res where k = 'first'), '1', 'the result carries its batch number');
select is((select count(*)::int from public.conversation_turns where text like '%Maya Chen%'), 150,
  '150 rows still name her');

-- The same batch again: the stored result, no more work.
insert into res select 'again', public.forget_erase_batch((select id from job), 1, 100);
select is((select result from res where k = 'again'), (select result from res where k = 'first'),
  'batch 1 twice returns the same result');
select is((select count(*)::int from public.conversation_turns where text like '%Maya Chen%'), 150,
  'and rewrote nothing the second time');

-- The same key with another size is refused.
select is(public.forget_erase_batch((select id from job), 1, 50),
  '{"status":"rejected","code":"keyReused"}'::jsonb, 'batch 1 with another size is keyReused');
select is((select count(*)::int from public.conversation_turns where text like '%Maya Chen%'), 150,
  'the keyReused call rewrote nothing');

select is((select p ->> 'nextBatch' from jsonb_array_elements(public.forget_erase_pending()) p), '2',
  'pending: now expects batch 2');
select is(public.forget_erase_batch((select id from job), 1, 100) -> 'rewritten', '100'::jsonb,
  'a repeat of batch 1 still gives its stored result after batch 2 is next');

-- Another user cannot run it.
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(public.forget_erase_batch((select id from job), 2, 100) -> 'finished', 'true'::jsonb,
  'another user''s batch finds no job (finished)');
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is((select count(*)::int from public.conversation_turns where text like '%Maya Chen%'), 150,
  'and rewrote nothing');

-- Batch 2, then the old step still works for the rest.
select is(public.forget_erase_batch((select id from job), 2, 100) ->> 'rewritten', '100', 'batch 2 rewrote 100 rows');
select is((select count(*)::int from public.conversation_turns where text like '%Maya Chen%'), 50, '50 left');
select is(public.forget_erase_step((select id from job), 100) ->> 'rewritten', '50',
  'forget_erase_step still works for an older client');

-- The job and its ledger go away together.
reset role;
select is((select count(*)::int from public.forget_erase_jobs), 0, 'the job is gone when finished');
select is((select count(*)::int from public.forget_erase_batches), 0, 'no ledger rows outlive the job');
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(public.forget_erase_batch(gen_random_uuid(), 1, 100) -> 'finished', 'true'::jsonb,
  'an unknown job comes back finished');

-- Forgetting the same person again restarts the job: batch numbers restart.
reset role;
insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen) values
  ('maya-chen', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Maya Chen', 'person', null, '{}', null, 1, now(), now());
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
delete from job;
insert into job select (public.forget_entity('maya-chen', true) ->> 'eraseJobId')::uuid;
select is(public.forget_erase_batch((select id from job), 1, 100) ->> 'finished', 'false', 'a second job: batch 1 ran');
reset role;
select is((select count(*)::int from public.forget_erase_batches), 1, 'its batch is in the ledger');
insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen) values
  ('maya-chen', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Maya Chen', 'person', null, '{}', null, 1, now(), now());
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(public.forget_entity('maya-chen', true) ->> 'eraseJobId', (select id::text from job),
  're-forgetting reuses the job');
select is((select p ->> 'nextBatch' from jsonb_array_elements(public.forget_erase_pending()) p), '1',
  'after the restart the job expects batch 1 again');
reset role;
select is((select count(*)::int from public.forget_erase_batches), 0, 'and its ledger rows are gone');

select * from finish();
rollback;
