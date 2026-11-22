-- pgTAP tests for get_entity_fact_history (EC-06): every live fact of the
-- given entities, for answering versions, changes, plans and totals in code.
create extension if not exists pgtap;

begin;
select plan(5);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, started_at) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'A', now());
insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen) values
  ('savings-goal', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'savings goal', 'concept', now(), now()),
  ('rent', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
   'rent', 'concept', now(), now());

create temp table ids (name text primary key, id uuid);
grant all on ids to public;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into ids select 'g2', public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":8000,"unit":"USD","status":"confirmed","statedAt":"2026-11-20T10:00:00Z"}');
insert into ids select 'g1', public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":5000,"unit":"USD","status":"confirmed","statedAt":"2026-11-03T10:00:00Z"}');
insert into ids select 'g3', public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":10000,"unit":"USD","status":"proposed","statedAt":"2026-11-21T10:00:00Z"}');
insert into ids select 'bad', public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":9999,"unit":"USD","status":"confirmed","statedAt":"2026-11-22T10:00:00Z"}');
select public.retract_memory_fact((select id from ids where name = 'bad'), 'corrected');
insert into ids select 'r1', public.insert_memory_fact('{"entityId":"rent","attribute":"amount","valueNum":1700,"unit":"USD","status":"confirmed","statedAt":"2026-11-05T10:00:00Z"}');

select is(
  (select array_agg(f ->> 'valueNum' order by ord)
     from jsonb_array_elements(public.get_entity_fact_history(array['savings-goal'])) with ordinality h(f, ord)),
  array['5000', '8000', '10000'], 'every live fact of the entity, in the order things were true');
select is(jsonb_array_length(public.get_entity_fact_history(array['savings-goal', 'rent'])), 4,
  'several entities at once');
select ok(not public.get_entity_fact_history(array['savings-goal'])::text like '%9999%',
  'a retracted fact is never returned');
select is(jsonb_array_length(public.get_entity_fact_history(null)), 0, 'nothing asked, nothing returned');

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(jsonb_array_length(public.get_entity_fact_history(array['savings-goal', 'rent'])), 0,
  'another user sees nothing');
reset role;

select * from finish();
rollback;
