-- pgTAP tests (EC-08): every privacy path covers the tables EC-02 to EC-07
-- added: memory_facts, conversation_state, memory_fact_corrections.
--   export_my_data  includes them
--   forget_entity   (Forget, Forget a person) deletes the person's facts, any
--                   fact or session state that names them, and their
--                   corrections
--   remove_entity   deletes the entity's facts
--   auto-forget     deleting an old entry deletes the facts said in it
--   delete_notebook deletes its facts and session state
--   account deletion deletes everything
-- Run: supabase test db   (or scripts/staging-db-test.py on staging)
create extension if not exists pgtap;

begin;
select plan(22);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, started_at, revision) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'One', now(), 1),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Two', now(), 1),
  ('b2222222-0000-0000-0000-000000000009', '22222222-2222-2222-2222-222222222222', 'B', now(), 1);
insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen) values
  ('maya', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Maya', 'person', now(), now()),
  ('savings-goal', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'savings goal', 'concept', now(), now()),
  ('dinner', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'dinner', 'event', now(), now()),
  ('rent', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'rent', 'concept', now(), now()),
  ('gym', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'gym', 'activity', now(), now()),
  ('maya', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000009', 'Maya', 'person', now(), now());
insert into public.journal_entries (id, user_id, notebook_id, text, entity_ids, created_at) values
  ('e0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'Maya''s birthday is March 3.', array['maya'], now()),
  ('e0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'My savings goal is 5k.', array['savings-goal'], now()),
  ('e0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002',
   'Rent is 1700.', array['rent'], now() - interval '400 days'),
  ('e0000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002',
   'The gym is 40 a month.', array['gym'], now());
update public.profiles set transcript_retention_days = 30 where user_id = '11111111-1111-1111-1111-111111111111';

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.insert_memory_fact('{"entityId":"maya","attribute":"birthday","valueText":"March 3","status":"confirmed","statedAt":"2026-11-01T10:00:00Z","sourceNotebookId":"a1111111-0000-0000-0000-000000000001","sourceEntryId":"e0000000-0000-0000-0000-000000000001"}');
select public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":5000,"unit":"USD","status":"confirmed","statedAt":"2026-11-02T10:00:00Z","sourceNotebookId":"a1111111-0000-0000-0000-000000000001","sourceEntryId":"e0000000-0000-0000-0000-000000000002"}');
select public.insert_memory_fact('{"entityId":"dinner","attribute":"with","valueText":"Maya","status":"proposed","statedAt":"2026-11-02T10:00:00Z","sourceNotebookId":"a1111111-0000-0000-0000-000000000001"}');
select public.insert_memory_fact('{"entityId":"rent","attribute":"amount","valueNum":1700,"unit":"USD","status":"confirmed","statedAt":"2025-10-01T10:00:00Z","sourceNotebookId":"a1111111-0000-0000-0000-000000000002","sourceEntryId":"e0000000-0000-0000-0000-000000000003"}');
select public.insert_memory_fact('{"entityId":"gym","attribute":"monthly cost","valueNum":40,"unit":"USD","status":"confirmed","statedAt":"2026-11-03T10:00:00Z","sourceNotebookId":"a1111111-0000-0000-0000-000000000002","sourceEntryId":"e0000000-0000-0000-0000-000000000004"}');
select public.propose_memory_correction('Maya', 'birthday', '{"valueText": "March 4"}');
select public.save_conversation_state('a1111111-0000-0000-0000-000000000001',
  '{"openThreads": ["How was dinner with Maya?"], "covered": ["Maya"]}');
select public.save_conversation_state('a1111111-0000-0000-0000-000000000002',
  '{"openThreads": ["How is the gym going?"], "covered": ["gym"]}');

-- B has their own Maya facts, untouched by anything A does.
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.insert_memory_fact('{"entityId":"maya","attribute":"birthday","valueText":"June 9","status":"confirmed","statedAt":"2026-11-01T10:00:00Z"}');
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── export ──────────────────────────────────────────────────────────────────
create temp table ex as select public.export_my_data() as data;
grant all on ex to public;
select is((select jsonb_array_length(n -> 'facts') from ex, jsonb_array_elements(data -> 'notebooks') n
            where n ->> 'title' = 'One'), 3, 'export: a notebook''s facts');
select is((select n -> 'sessionState' -> 'openThreads' ->> 0 from ex, jsonb_array_elements(data -> 'notebooks') n
            where n ->> 'title' = 'One'), 'How was dinner with Maya?', 'export: its session state');
select is((select jsonb_array_length(n -> 'corrections') from ex, jsonb_array_elements(data -> 'notebooks') n
            where n ->> 'title' = 'One'), 1, 'export: its corrections');
select is((select array_agg(k order by k) from ex, jsonb_array_elements(data -> 'notebooks') n,
                   jsonb_object_keys(n -> 'facts' -> 0) k where n ->> 'title' = 'Two'),
  array['attribute','entityId','eventAt','id','provenance','sourceEntryId','sourceNotebookId',
        'statedAt','status','supersedesFactId','unit','valueNum','valueText'],
  'export: facts use the fact contract (contracts/memory-fact-v1.schema.json)');

-- ── forget a person ─────────────────────────────────────────────────────────
select lives_ok($$ select public.forget_entity('maya') $$, 'Maya is forgotten');
select is((select count(*)::int from public.memory_facts where entity_id = 'maya'), 0,
  'forget: her facts are gone');
select is((select count(*)::int from public.memory_facts where entity_id = 'dinner'), 0,
  'forget: a fact whose value names her is gone');
select is((select count(*)::int from public.memory_facts where entity_id = 'savings-goal'), 1,
  'forget: other facts stay');
select is((select count(*)::int from public.memory_fact_corrections), 0, 'forget: her corrections are gone');
select is((select count(*)::int from public.conversation_state
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'), 0,
  'forget: session state that names her is gone');
select is((select count(*)::int from public.conversation_state
            where notebook_id = 'a1111111-0000-0000-0000-000000000002'), 1,
  'forget: session state that does not name her stays');

-- ── remove from memory ──────────────────────────────────────────────────────
select lives_ok($$ select public.remove_entity('savings-goal') $$, 'the savings goal is removed');
select is((select count(*)::int from public.memory_facts where entity_id = 'savings-goal'), 0,
  'remove: its facts are gone');
reset role;
select is((select count(*)::int from public.memory_facts where user_id = '22222222-2222-2222-2222-222222222222'), 1,
  'forget: another user''s Maya is untouched');

-- ── auto-forget ─────────────────────────────────────────────────────────────
select lives_ok($$ select public.forget_old_transcripts() $$, 'the retention sweep runs');
select is((select count(*)::int from public.memory_facts where entity_id = 'rent'), 0,
  'auto-forget: a fact said in a deleted entry goes with it');
select is((select count(*)::int from public.memory_facts where entity_id = 'gym'), 1,
  'auto-forget: a recent fact stays');

-- ── delete a notebook ───────────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select lives_ok($$ select public.delete_notebook('a1111111-0000-0000-0000-000000000002') $$, 'notebook Two is deleted');
reset role;
select is((select count(*)::int from public.memory_facts where user_id = '11111111-1111-1111-1111-111111111111'), 0,
  'delete notebook: its facts are gone');
select is((select count(*)::int from public.conversation_state where user_id = '11111111-1111-1111-1111-111111111111'), 0,
  'delete notebook: its session state is gone');

-- ── delete the account ──────────────────────────────────────────────────────
delete from auth.users where id = '22222222-2222-2222-2222-222222222222';
select is((select count(*)::int from public.memory_facts where user_id = '22222222-2222-2222-2222-222222222222'), 0,
  'account deletion: every fact is gone');
select is((select count(*)::int from public.memory_facts), 0, 'and nothing of anyone is left here');

select * from finish();
rollback;
