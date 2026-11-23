-- pgTAP tests for the correction flow (EC-07): propose, read back, confirm.
-- Nothing changes until the user confirms. A confirmed correction retracts
-- the wrong fact (never shown again, not even as history) and stores the
-- right one pinned (provenance user_corrected).
create extension if not exists pgtap;

begin;
select plan(30);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, started_at) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'A', now());
insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen) values
  ('savings-goal', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'savings goal', 'concept', now(), now()),
  ('rent', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'rent', 'concept', now(), now()),
  ('gym', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'gym membership', 'activity', now(), now()),
  ('priya', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'Priya', 'person', now(), now()),
  ('me-run', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'my run', 'activity', now(), now());

create temp table out (name text primary key, result jsonb);
grant all on out to public;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":5000,"unit":"USD","status":"confirmed","statedAt":"2026-11-03T10:00:00Z"}');
select public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":8000,"unit":"USD","status":"confirmed","statedAt":"2026-11-20T10:00:00Z"}');
select public.insert_memory_fact('{"entityId":"rent","attribute":"amount","valueNum":1700,"unit":"USD","status":"confirmed","statedAt":"2026-11-05T10:00:00Z"}');
select public.insert_memory_fact('{"entityId":"rent","attribute":"due_day","valueText":"the 1st","status":"confirmed","statedAt":"2026-11-05T10:00:00Z"}');
select public.insert_memory_fact('{"entityId":"gym","attribute":"status","valueText":"cancelled","status":"confirmed","statedAt":"2026-11-06T10:00:00Z"}');
select public.insert_memory_fact('{"entityId":"me-run","attribute":"distance","valueNum":10,"unit":"km","status":"confirmed","eventAt":"2026-11-17T12:00:00Z","statedAt":"2026-11-22T10:00:00Z"}');

-- ── a value correction: read back, nothing written until confirmed ──────────
insert into out select 'p1', public.propose_memory_correction('savings goal', 'amount', '{"valueNum": 7000}');
select is((select result ->> 'status' from out where name = 'p1'), 'pending', 'a correction is proposed');
select is((select result ->> 'readBack' from out where name = 'p1'),
  'So your savings goal amount is 7000 USD, not 8000 USD. Is that right?',
  'the read-back sentence is built by code');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'valueNum', '8000',
  'nothing changes before the user confirms');

insert into out select 'a1', public.apply_memory_correction((select (result ->> 'correctionId')::uuid from out where name = 'p1'));
select is((select result ->> 'status' from out where name = 'a1'), 'applied', 'confirmed: applied');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'valueNum', '7000',
  'the corrected value is current');
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'provenance', 'user_corrected',
  'and pinned');
select is(public.get_memory_fact('savings-goal', 'amount', 'previous') -> 'fact' ->> 'valueNum', '5000',
  'previous never returns the wrong value');
select ok(not public.get_memory_fact_history('savings-goal', 'amount')::text like '%8000%',
  'the wrong value is not even history');
select is(public.apply_memory_correction((select (result ->> 'correctionId')::uuid from out where name = 'p1')) ->> 'status',
  'not_pending', 'applying twice does nothing');

-- ── re-extraction after the correction keeps it ─────────────────────────────
reset role;
insert into public.journal_entries (id, user_id, notebook_id, text, entity_ids, created_at) values
  ('e0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', 'Raised it to 8k.', array['savings-goal'], '2026-11-20T10:00:00Z');
set local role authenticated;
select public.record_memory_facts('33333333-3333-3333-3333-333333333333', 'e0000000-0000-0000-0000-000000000001',
  '[{"entityId":"savings-goal","attribute":"amount","valueNum":8000,"unit":"USD","status":"confirmed"}]', true);
select is(public.get_memory_fact('savings-goal', 'amount') -> 'fact' ->> 'valueNum', '7000',
  're-extracting the old entry cannot bring the wrong value back');

-- ── rejected read-backs: after two, offer to remove ─────────────────────────
insert into out select 'p2', public.propose_memory_correction('rent', 'amount', '{"valueNum": 1650}');
insert into out select 'r1', public.reject_memory_correction((select (result ->> 'correctionId')::uuid from out where name = 'p2'));
select is((select (result ->> 'offerRemoval')::boolean from out where name = 'r1'), false, 'one rejection: ask again');
insert into out select 'p3', public.propose_memory_correction('rent', 'amount', '{"valueNum": 1600}');
insert into out select 'r2', public.reject_memory_correction((select (result ->> 'correctionId')::uuid from out where name = 'p3'));
select is((select (result ->> 'offerRemoval')::boolean from out where name = 'r2'), true,
  'two rejected read-backs for one fact: offer to remove it');
select is(public.get_memory_fact('rent', 'amount') -> 'fact' ->> 'valueNum', '1700', 'rejections change nothing');

-- ── removal ─────────────────────────────────────────────────────────────────
insert into out select 'p4', public.propose_memory_correction('rent', 'amount', '{"remove": true}');
select is((select result ->> 'readBack' from out where name = 'p4'),
  'So I should forget that your rent amount is 1700 USD. Is that right?', 'a removal is read back too');
select is(public.apply_memory_correction((select (result ->> 'correctionId')::uuid from out where name = 'p4')) ->> 'status',
  'applied', 'removal confirmed');
select is(public.get_memory_fact('rent', 'amount') -> 'fact', 'null'::jsonb, 'the fact is gone');

-- ── status, date and attribution corrections ────────────────────────────────
insert into out select 'p5', public.propose_memory_correction('gym membership', null, '{"status": "proposed"}');
select is((select result ->> 'readBack' from out where name = 'p5'),
  'So your gym membership status cancelled was only planned, not done. Is that right?', 'a status correction');
select public.apply_memory_correction((select (result ->> 'correctionId')::uuid from out where name = 'p5'));
select is(public.get_memory_fact_history('gym', 'status') -> 'facts' -> 0 ->> 'status', 'proposed',
  'the plan is what is stored now');
select is(jsonb_array_length(public.get_memory_fact_history('gym', 'status') -> 'facts'), 1,
  'and the wrong "done" is gone');

insert into out select 'p6', public.propose_memory_correction('my run', 'distance', '{"eventAt": "2026-11-18T12:00:00Z"}');
select is((select result ->> 'readBack' from out where name = 'p6'),
  'So your my run distance of 10 km was on 18 Nov 2026, not 17 Nov 2026. Is that right?', 'a date correction');
select public.apply_memory_correction((select (result ->> 'correctionId')::uuid from out where name = 'p6'));
select is(public.get_memory_fact('me-run', 'distance') -> 'fact' ->> 'eventAt', '2026-11-18T12:00:00+00:00',
  'the date is corrected');

insert into out select 'p7', public.propose_memory_correction('rent', 'due day', '{"entity": "Priya"}');
select is((select result ->> 'readBack' from out where name = 'p7'),
  'So it was Priya''s due day that is the 1st, not your rent''s. Is that right?', 'an attribution correction');
select public.apply_memory_correction((select (result ->> 'correctionId')::uuid from out where name = 'p7'));
select is(public.get_memory_fact('priya', 'due_day') -> 'fact' ->> 'valueText', 'the 1st', 'it moves to the right entity');
select is(public.get_memory_fact('rent', 'due_day') -> 'fact', 'null'::jsonb, 'and leaves the wrong one');

-- ── what cannot be corrected, or needs a question ───────────────────────────
select is(public.propose_memory_correction('nobody', null, '{"valueNum": 1}') ->> 'status', 'not_found',
  'an unknown thing is not found');
select public.insert_memory_fact('{"entityId":"rent","attribute":"amount","valueNum":1800,"unit":"USD","status":"confirmed","statedAt":"2026-11-21T10:00:00Z"}');
select public.insert_memory_fact('{"entityId":"rent","attribute":"deposit","valueNum":3000,"unit":"USD","status":"confirmed","statedAt":"2026-11-21T10:00:00Z"}');
insert into out select 'ask', public.propose_memory_correction('rent', null, '{"valueNum": 1900}');
select is((select result ->> 'status' from out where name = 'ask'), 'ask', 'more than one fact fits: ask which');
select is((select result ->> 'question' from out where name = 'ask'), 'Which do you mean: rent amount or rent deposit?',
  'one targeted question');
select throws_ok($$ select public.propose_memory_correction('rent', 'amount', '{}'::jsonb) $$, '22023', null,
  'a correction must change something');

-- ── another user cannot touch any of it ─────────────────────────────────────
insert into out select 'p8', public.propose_memory_correction('rent', 'amount', '{"valueNum": 1950}');
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(public.apply_memory_correction((select (result ->> 'correctionId')::uuid from out where name = 'p8')) ->> 'status',
  'not_pending', 'B cannot apply A''s correction');
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(public.get_memory_fact('rent', 'amount') -> 'fact' ->> 'valueNum', '1800', 'A''s fact is untouched');
reset role;

select * from finish();
rollback;
