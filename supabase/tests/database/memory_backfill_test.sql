-- pgTAP tests for the fact backfill's cursor (EC-09): list_backfill_entries,
-- advance_memory_backfill, reset_memory_backfill.
--   * the user's own words only: Lumen's lines and entries linked to no
--     entity are skipped
--   * oldest first, from the cursor on, so a run can stop and resume
--   * the Forget-redacted text (context_text) when there is one
create extension if not exists pgtap;

begin;
select plan(12);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, started_at) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'A', now()),
  ('b2222222-0000-0000-0000-000000000009', '22222222-2222-2222-2222-222222222222', 'B', now());
insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen) values
  ('savings-goal', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'savings goal', 'concept', now(), now()),
  ('rent', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'rent', 'concept', now(), now());
-- Maya was forgotten: the database keeps entries' context_text redacted.
insert into public.entity_suppressions (user_id, entity_hash, kind, match_inside)
  values ('11111111-1111-1111-1111-111111111111',
          public._suppression_hash('11111111-1111-1111-1111-111111111111', 'maya'), 'forgotten', false);
insert into public.journal_entries (id, user_id, notebook_id, text, context_text, entity_ids, created_at) values
  ('e0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'Rent is 1700 since I spoke to Maya.', 'Rent is 1700 since I spoke to someone.', array['rent'], '2026-10-02T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'My savings goal is 5k.', null, array['savings-goal'], '2026-10-01T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'Your savings goal is 5k, right?', null, array['savings-goal'], '2026-10-03T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'Just a quiet day.', null, array[]::text[], '2026-10-04T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'Raised the savings goal to 8k.', null, array['savings-goal'], '2026-10-05T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000009', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000009',
   'B''s goal is 9k.', null, array['savings-goal'], '2026-10-01T09:00:00Z');
-- Lumen said entry 3 (it is in the transcript as the assistant's turn).
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at, created_at) values
  ('a1111111-0000-0000-0000-000000000001', 't3', '11111111-1111-1111-1111-111111111111', 'assistant',
   'Your savings goal is 5k, right?', '2026-10-03T10:00:00Z', '2026-10-03T10:00:00Z');

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

create temp table got as select public.list_backfill_entries(10) as page;
grant all on got to public;
select is((select array_agg(e ->> 'entryId' order by ord) from got, jsonb_array_elements(page) with ordinality p(e, ord)),
  array['e0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000002',
        'e0000000-0000-0000-0000-000000000005'],
  'the user''s own entries with entities, oldest first; Lumen''s line and the entity-less one are skipped');
select is((select e ->> 'text' from got, jsonb_array_elements(page) e
            where e ->> 'entryId' = 'e0000000-0000-0000-0000-000000000002'),
  'Rent is 1700 since I spoke to someone.', 'the Forget-redacted text is what gets extracted');
select is((select e -> 'entities' -> 0 ->> 'name' from got, jsonb_array_elements(page) e
            where e ->> 'entryId' = 'e0000000-0000-0000-0000-000000000001'),
  'savings goal', 'each entry comes with its entities');
select is((select e ->> 'spokenAt' from got, jsonb_array_elements(page) e
            where e ->> 'entryId' = 'e0000000-0000-0000-0000-000000000001'),
  '2026-10-01T10:00:00+00:00', 'and when it was said');

select public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":8000,"unit":"USD","status":"confirmed","statedAt":"2026-10-05T10:00:00Z","sourceNotebookId":"a1111111-0000-0000-0000-000000000001","sourceEntryId":"e0000000-0000-0000-0000-000000000005"}');
select is((select (e ->> 'hasFacts')::boolean from jsonb_array_elements(public.list_backfill_entries(10)) e
            where e ->> 'entryId' = 'e0000000-0000-0000-0000-000000000005'), true,
  'an entry extracted live since EC-03 says so, and the script leaves it alone');
select is(jsonb_array_length(public.list_backfill_entries(1)), 1, 'pages are capped');
select lives_ok($$ select public.advance_memory_backfill('e0000000-0000-0000-0000-000000000001') $$, 'the cursor moves');
select is(public.list_backfill_entries(10) -> 0 ->> 'entryId', 'e0000000-0000-0000-0000-000000000002',
  'a resumed run starts after the last entry done');
select public.advance_memory_backfill('e0000000-0000-0000-0000-000000000005');
select is(jsonb_array_length(public.list_backfill_entries(10)), 0, 'done: nothing left');
select throws_ok($$ select public.advance_memory_backfill('e0000000-0000-0000-0000-000000000009') $$, '22023', null,
  'the cursor only moves over one''s own entries');
select lives_ok($$ select public.reset_memory_backfill() $$, 'it can start over');
select is(jsonb_array_length(public.list_backfill_entries(10)), 3, 'from the beginning');
reset role;

select * from finish();
rollback;
