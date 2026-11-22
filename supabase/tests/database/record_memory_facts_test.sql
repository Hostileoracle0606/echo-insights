-- pgTAP tests for write-time fact upserts (EC-03): record_memory_facts and
-- list_memory_fact_keys. Run: supabase test db (or scripts/staging-db-test.py).
--
-- Each extracted fact either confirms what is stored (a repeat: no new row),
-- supersedes it (a real change: the old row stays as history), or is ignored
-- because the user corrected that value later (pinned). "From X to Y" records
-- Y and confirms X as the prior version.
create extension if not exists pgtap;

begin;
select plan(31);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, started_at) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'A', now()),
  ('44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', 'B', now());
insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen) values
  ('savings-goal', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'savings goal', 'concept', now(), now()),
  ('rent', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'rent', 'concept', now(), now()),
  ('priya', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'Priya', 'person', now(), now());
-- One entry per turn, said on successive days.
insert into public.journal_entries (id, user_id, notebook_id, text, entity_ids, created_at) values
  ('e0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', 'My savings goal is 5k.', array['savings-goal'], '2026-11-03T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', 'Still 5k.', array['savings-goal'], '2026-11-04T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', 'Raised it to 8k.', array['savings-goal'], '2026-11-20T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', 'Back in October it was 3k.', array['savings-goal'], '2026-11-21T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', 'Rent went from 1500 to 1700.', array['rent'], '2026-11-05T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', 'Priya is moving to Lisbon.', array['priya'], '2026-11-01T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', 'old entry re-extracted', array['savings-goal'], '2026-11-10T10:00:00Z'),
  ('e0000000-0000-0000-0000-000000000008', '22222222-2222-2222-2222-222222222222',
   '44444444-4444-4444-4444-444444444444', 'B''s entry', array[]::text[], now());

create temp table out (name text primary key, result jsonb);
grant all on out to public;

set local role anon;
select throws_ok($$ select public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000001', '[]'::jsonb) $$, '42501', null, 'anon cannot record facts');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── first statement: inserted, said at the entry's time ─────────────────────
insert into out select 'first', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000001',
  '[{"entityId":"savings-goal","attribute":"Amount","valueNum":5000,"unit":"USD","status":"confirmed"}]');
select is((select result -> 'recorded' -> 0 ->> 'outcome' from out where name = 'first'), 'inserted',
  'a new fact is inserted');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'statedAt',
  '2026-11-03T10:00:00+00:00', 'statedAt is when the entry was said');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'sourceEntryId',
  'e0000000-0000-0000-0000-000000000001', 'the fact points at its entry');

-- ── a repeat writes nothing ─────────────────────────────────────────────────
insert into out select 'repeat', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000002',
  '[{"entityId":"savings-goal","attribute":"amount","valueNum":5000,"unit":"usd","status":"confirmed"}]');
select is((select result -> 'recorded' -> 0 ->> 'outcome' from out where name = 'repeat'), 'repeat',
  'the same value again is a repeat');
select is((select count(*)::int from public.memory_facts where entity_id = 'savings-goal'), 1,
  'a repeat creates no row');

-- ── a change supersedes; the old value is history ───────────────────────────
insert into out select 'change', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000003',
  '[{"entityId":"savings-goal","attribute":"amount","valueNum":8000,"unit":"USD","status":"confirmed"}]');
select is((select result -> 'recorded' -> 0 ->> 'outcome' from out where name = 'change'), 'superseded',
  'a different value supersedes');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'valueNum', '8000',
  'the new value is current');
select is(public.get_memory_fact('savings-goal', 'amount', 'previous') -> 'fact' ->> 'valueNum', '5000',
  'the old value is previous');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'supersedesFactId',
  public.get_memory_fact('savings-goal', 'amount', 'previous') -> 'fact' ->> 'id',
  'and is linked as the one superseded');

-- ── said late about an earlier time: history, not current ───────────────────
insert into out select 'late', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000004',
  '[{"entityId":"savings-goal","attribute":"amount","valueNum":3000,"unit":"USD","status":"confirmed",
     "eventAt":"2026-10-01T00:00:00Z"}]');
select is((select result -> 'recorded' -> 0 ->> 'outcome' from out where name = 'late'), 'history',
  'an earlier value said later goes into history');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'valueNum', '8000',
  'the current value is unchanged');
select is(
  (select array_agg(f ->> 'valueNum' order by ord)
     from jsonb_array_elements(public.get_memory_fact_history('savings-goal', 'amount') -> 'facts')
       with ordinality as h(f, ord)),
  array['3000', '5000', '8000'], 'history is in the order things were true');

-- ── "from X to Y": Y supersedes, X is confirmed as the prior version ────────
insert into out select 'fromto', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000005',
  '[{"entityId":"rent","attribute":"monthly amount","valueNum":1700,"unit":"USD","status":"confirmed",
     "previousValueNum":1500}]');
select is(public.get_memory_fact('rent', 'monthly amount') -> 'fact' ->> 'valueNum', '1700',
  'the new value of a change is current');
select is(public.get_memory_fact('rent', 'monthly amount', 'previous') -> 'fact' ->> 'valueNum', '1500',
  'the value it changed from is recorded as the previous version');
select is((select count(*)::int from public.memory_facts where entity_id = 'rent'), 2,
  'one row for each side of the change');
insert into out select 'fromto2', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000005',
  '[{"entityId":"rent","attribute":"monthly amount","valueNum":1700,"unit":"USD","status":"confirmed",
     "previousValueNum":1500}]');
select is((select count(*)::int from public.memory_facts where entity_id = 'rent'), 2,
  'recording the same turn again adds nothing');

-- ── plans are their own status ──────────────────────────────────────────────
insert into out select 'plan', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000006',
  '[{"entityId":"priya","attribute":"moving_to","valueText":"Lisbon","status":"proposed",
     "eventAt":"2026-12-01T00:00:00Z"}]');
select is(public.get_memory_fact_history('priya', 'moving_to') -> 'facts' -> 0 ->> 'status', 'proposed',
  'a plan is stored as proposed');
insert into out select 'plan2', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000006',
  '[{"entityId":"priya","attribute":"moving_to","valueText":"lisbon","status":"proposed"}]');
select is(jsonb_array_length(public.get_memory_fact_history('priya', 'moving_to') -> 'facts'), 1,
  'the same plan again is a repeat (text compared case-insensitively)');

-- ── bad input is skipped, not fatal ─────────────────────────────────────────
insert into out select 'bad', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000006',
  '[{"entityId":"nobody","attribute":"x","valueNum":1,"status":"confirmed"},
    {"entityId":"priya","attribute":"","valueNum":1,"status":"confirmed"},
    {"entityId":"priya","attribute":"age","status":"confirmed"}]');
select is((select (result ->> 'skipped')::int from out where name = 'bad'), 3,
  'unknown entities, empty attributes and missing values are skipped');
select throws_ok($$ select public.record_memory_facts('44444444-4444-4444-4444-444444444444',
  'e0000000-0000-0000-0000-000000000008', '[]'::jsonb) $$, '22023', null,
  'facts can only be recorded for one''s own entry');
select throws_ok($$ select public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000001', '{}'::jsonb) $$, '22023', null,
  'facts must be an array');

-- ── a pinned correction wins over an older statement re-extracted ───────────
-- The user corrected the goal to 7000 on 22 Nov (EC-07 writes this).
select lives_ok($$ select public.insert_memory_fact(jsonb_build_object(
  'entityId', 'savings-goal', 'attribute', 'amount', 'valueNum', 7000, 'unit', 'USD',
  'status', 'confirmed', 'statedAt', '2026-11-22T10:00:00Z', 'provenance', 'user_corrected')) $$,
  'a correction is pinned');
insert into out select 'pinned', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000007',
  '[{"entityId":"savings-goal","attribute":"amount","valueNum":9999,"unit":"USD","status":"confirmed"}]');
select is((select result -> 'recorded' -> 0 ->> 'outcome' from out where name = 'pinned'), 'pinned',
  'an extraction said before the correction cannot override it');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'valueNum', '7000',
  'the corrected value stays current');

-- ── re-deriving an entry replaces its extracted facts, keeps corrections ────
insert into out select 'rederive', public.record_memory_facts('33333333-3333-3333-3333-333333333333',
  'e0000000-0000-0000-0000-000000000005',
  '[{"entityId":"rent","attribute":"monthly amount","valueNum":1800,"unit":"USD","status":"confirmed"}]',
  true);
select is((select count(*)::int from public.memory_facts where entity_id = 'rent'), 1,
  'the entry''s old facts are replaced');
select is(public.get_memory_fact('rent', 'monthly amount') -> 'fact' ->> 'valueNum', '1800',
  'by what the edited entry now says');
select is((select count(*)::int from public.memory_facts where provenance = 'user_corrected'), 1,
  'corrections survive re-derivation');

-- ── existing keys, for the extraction prompt ────────────────────────────────
select is(
  (select array_agg((k ->> 'entityId') || '.' || (k ->> 'attribute') order by 1)
     from jsonb_array_elements(public.list_memory_fact_keys(array['savings-goal', 'rent'])) k),
  array['rent.monthly amount', 'savings-goal.amount'],
  'list_memory_fact_keys returns the live keys of the given entities');
select is(jsonb_array_length(public.list_memory_fact_keys(array['priya'])), 1,
  'only for the entities asked about');

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(jsonb_array_length(public.list_memory_fact_keys(array['savings-goal'])), 0,
  'another user sees none of these keys');
reset role;

select * from finish();
rollback;
