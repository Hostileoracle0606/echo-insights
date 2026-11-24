-- pgTAP tests for get_current_facts (EC-05): the working set's facts.
-- One current confirmed value per entity attribute, plus any plan or
-- cancellation said after it. Retracted facts and other users never appear.
create extension if not exists pgtap;

begin;
select plan(7);

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
insert into ids select 'g1', public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":5000,"unit":"USD","status":"confirmed","statedAt":"2026-11-03T10:00:00Z"}');
insert into ids select 'g2', public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":8000,"unit":"USD","status":"confirmed","statedAt":"2026-11-20T10:00:00Z"}');
insert into ids select 'g3', public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":10000,"unit":"USD","status":"proposed","statedAt":"2026-11-21T10:00:00Z"}');
insert into ids select 'old-plan', public.insert_memory_fact('{"entityId":"savings-goal","attribute":"amount","valueNum":6000,"unit":"USD","status":"proposed","statedAt":"2026-11-10T10:00:00Z"}');
insert into ids select 'r1', public.insert_memory_fact('{"entityId":"rent","attribute":"amount","valueNum":1700,"unit":"USD","status":"confirmed","statedAt":"2026-11-05T10:00:00Z"}');
insert into ids select 'r2', public.insert_memory_fact('{"entityId":"rent","attribute":"amount","valueNum":1900,"unit":"USD","status":"confirmed","statedAt":"2026-11-06T10:00:00Z"}');
select public.retract_memory_fact((select id from ids where name = 'r2'), 'corrected');

create temp table got as
  select f from jsonb_array_elements(public.get_current_facts(array['savings-goal', 'rent'])) f;
grant all on got to public;

select is((select count(*)::int from got where f ->> 'entityId' = 'savings-goal' and f ->> 'status' = 'confirmed'), 1,
  'one current confirmed value per attribute');
select is((select f ->> 'valueNum' from got where f ->> 'entityId' = 'savings-goal' and f ->> 'status' = 'confirmed'), '8000',
  'the latest confirmed value');
select is((select array_agg(f ->> 'valueNum') from got where f ->> 'entityId' = 'savings-goal' and f ->> 'status' = 'proposed'),
  array['10000'], 'a plan said after it is kept; one said before it is not');
select is((select f ->> 'valueNum' from got where f ->> 'entityId' = 'rent'), '1700',
  'a retracted value never shows; the one before it is current');
select is(jsonb_array_length(public.get_current_facts(array['rent'])), 1, 'only the entities asked for');
select is(jsonb_array_length(public.get_current_facts(array[]::text[])), 0, 'none asked, none returned');

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(jsonb_array_length(public.get_current_facts(array['savings-goal', 'rent'])), 0,
  'another user sees nothing');
reset role;

select * from finish();
rollback;
