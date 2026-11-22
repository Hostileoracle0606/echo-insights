-- pgTAP tests for the fact layer (EC-02): memory_facts and its RPCs.
-- Run: supabase test db   (or scripts/staging-db-test.py on staging)
--
-- A fact is one typed value of an entity's attribute ("savings-goal.amount =
-- 8000 USD"). A real change supersedes (the old value stays as history); a
-- correction retracts (the wrong value never appears again, not even as
-- history). Writes go through security-definer RPCs only.
create extension if not exists pgtap;

begin;
select plan(33);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, started_at) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'A', now()),
  ('44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', 'B', now());
insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen) values
  ('savings-goal', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'savings goal', 'concept', now(), now()),
  ('priya', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'Priya', 'person', now(), now());
insert into public.journal_entries (id, user_id, notebook_id, text, entity_ids, created_at) values
  ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', 'My savings goal is 5k.', array['savings-goal'], now());

create temp table ids (name text primary key, id uuid);
grant all on ids to public;

select has_table('public', 'memory_facts', 'memory_facts exists');
select ok((select relrowsecurity from pg_class where oid = 'public.memory_facts'::regclass),
  'row level security is on');
select has_index('public', 'memory_facts', 'memory_facts_version_idx',
  'version lookups are indexed');

-- ── anon can do nothing ─────────────────────────────────────────────────────
set local role anon;
select throws_ok($$ select public.insert_memory_fact('{}'::jsonb) $$, '42501', null,
  'anon cannot write facts');
select throws_ok($$ select public.get_memory_fact('savings-goal', 'amount') $$, '42501', null,
  'anon cannot read facts');
reset role;

-- ── user A writes ───────────────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

insert into ids select 'f1', public.insert_memory_fact('{
  "entityId": "savings-goal", "attribute": " Amount ", "valueNum": 5000, "unit": "USD",
  "status": "confirmed", "statedAt": "2026-11-03T10:00:00Z",
  "sourceNotebookId": "33333333-3333-3333-3333-333333333333",
  "sourceEntryId": "55555555-5555-5555-5555-555555555555"
}'::jsonb);
select ok((select id from ids where name = 'f1') is not null, 'a fact is written and returns its id');
select is((select attribute from public.memory_facts where id = (select id from ids where name = 'f1')),
  'amount', 'attributes are normalised (trimmed, lower case)');
select is((select provenance from public.memory_facts where id = (select id from ids where name = 'f1')),
  'extracted', 'provenance defaults to extracted');

select throws_ok($$ select public.insert_memory_fact('{"entityId": "nobody", "attribute": "amount",
  "valueNum": 1, "status": "confirmed", "statedAt": "2026-11-03T10:00:00Z"}'::jsonb) $$,
  '22023', null, 'a fact must belong to one of the user''s entities');
select throws_ok($$ select public.insert_memory_fact('{"entityId": "savings-goal", "attribute": "amount",
  "status": "confirmed", "statedAt": "2026-11-03T10:00:00Z"}'::jsonb) $$,
  '22023', null, 'a fact needs a value');
select throws_ok($$ select public.insert_memory_fact('{"entityId": "savings-goal", "attribute": "amount",
  "valueNum": 1, "status": "done", "statedAt": "2026-11-03T10:00:00Z"}'::jsonb) $$,
  '22023', null, 'status must be confirmed, proposed or cancelled');
select throws_ok($$ insert into public.memory_facts (user_id, entity_id, attribute, value_num, status, stated_at)
  values ('11111111-1111-1111-1111-111111111111', 'savings-goal', 'amount', 1, 'confirmed', now()) $$,
  '42501', null, 'facts cannot be inserted directly, only through the RPC');

-- A real change supersedes: the old value stays as history.
insert into ids select 'f2', public.insert_memory_fact(jsonb_build_object(
  'entityId', 'savings-goal', 'attribute', 'amount', 'valueNum', 8000, 'unit', 'USD',
  'status', 'confirmed', 'statedAt', '2026-11-20T10:00:00Z',
  'supersedesFactId', (select id from ids where name = 'f1')));
-- A plan does not replace the confirmed value.
insert into ids select 'p1', public.insert_memory_fact('{
  "entityId": "savings-goal", "attribute": "amount", "valueNum": 9000, "unit": "USD",
  "status": "proposed", "statedAt": "2026-11-21T10:00:00Z"}'::jsonb);
-- Said late, about an earlier time: ordered by when it happened.
insert into ids select 'f0', public.insert_memory_fact('{
  "entityId": "savings-goal", "attribute": "amount", "valueNum": 3000, "unit": "USD",
  "status": "confirmed", "eventAt": "2026-10-01T00:00:00Z", "statedAt": "2026-11-22T10:00:00Z"}'::jsonb);
-- A text value.
select lives_ok($$ select public.insert_memory_fact('{"entityId": "priya", "attribute": "moving_to",
  "valueText": "Lisbon", "status": "proposed", "eventAt": "2026-12-01T00:00:00Z",
  "statedAt": "2026-11-01T10:00:00Z"}'::jsonb) $$, 'a text fact is written');

select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'valueNum', '8000',
  'current is the latest confirmed value');
select is(
  (select array_agg(k order by k) from jsonb_object_keys(public.get_memory_fact('savings-goal', 'amount') -> 'fact') k),
  array['attribute','entityId','eventAt','id','provenance','sourceEntryId','sourceNotebookId',
        'statedAt','status','supersedesFactId','unit','valueNum','valueText'],
  'a fact has exactly the fields of contracts/memory-fact-v1.schema.json');
select is(public.get_memory_fact('savings-goal', 'AMOUNT') -> 'fact' ->> 'valueNum', '8000',
  'reads normalise the attribute too');
select is(public.get_memory_fact('savings-goal', 'amount', 'previous') -> 'fact' ->> 'valueNum', '5000',
  'previous is the confirmed value before the current one');
select is(public.get_memory_fact('savings-goal', 'amount', 'as_of', '2026-11-10T00:00:00Z') -> 'fact' ->> 'valueNum',
  '5000', 'as of a date is the confirmed value in effect then');
select is(public.get_memory_fact('savings-goal', 'amount', 'as_of', '2026-09-01T00:00:00Z') -> 'fact',
  'null'::jsonb, 'as of a date before any value is null');
select is(
  (select array_agg(f ->> 'valueNum' order by ord)
     from jsonb_array_elements(public.get_memory_fact_history('savings-goal', 'amount') -> 'facts')
       with ordinality as h(f, ord)),
  array['3000', '5000', '8000', '9000'],
  'history is every live version, oldest first, plans included');
select is(
  (select f ->> 'status' from jsonb_array_elements(public.get_memory_fact_history('savings-goal', 'amount') -> 'facts') f
    where f ->> 'valueNum' = '9000'),
  'proposed', 'history keeps the status of a plan');
select is(public.get_memory_fact('priya', 'moving_to') -> 'fact', 'null'::jsonb,
  'a plan alone is not a current confirmed value');
select is(public.get_memory_fact_history('priya', 'moving_to') -> 'facts' -> 0 ->> 'valueText', 'Lisbon',
  'but it is in history');
select throws_ok($$ select public.get_memory_fact('savings-goal', 'amount', 'someday') $$, '22023', null,
  'unknown scopes are rejected');

-- ── user B sees and changes nothing of A's ──────────────────────────────────
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is((select count(*)::int from public.memory_facts), 0, 'B cannot read A''s facts');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact', 'null'::jsonb,
  'B''s reads never return A''s facts');
select is(public.retract_memory_fact((select id from ids where name = 'f2'), 'corrected'), false,
  'B cannot retract A''s fact');

-- ── a correction retracts: gone from every read, even history ───────────────
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select throws_ok(format($$ select public.retract_memory_fact(%L, 'oops') $$, (select id from ids where name = 'f2')),
  '22023', null, 'retraction needs a known reason');
select is(public.retract_memory_fact((select id from ids where name = 'f2'), 'corrected'), true,
  'A retracts the wrong value');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'valueNum', '5000',
  'current falls back to the last value that was really true');
select is(public.get_memory_fact('savings-goal', 'amount', 'previous') -> 'fact' ->> 'valueNum', '3000',
  'previous skips the retracted value');
select ok(not public.get_memory_fact_history('savings-goal', 'amount')::text like '%8000%',
  'the retracted value is not in history');
select is((select count(*)::int from public.memory_facts where value_num = 8000), 0,
  'direct reads never see a retracted fact');
reset role;

select * from finish();
rollback;
