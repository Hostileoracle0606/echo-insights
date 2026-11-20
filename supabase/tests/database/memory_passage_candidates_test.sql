begin;
create extension if not exists pgtap;
select plan(7);
insert into auth.users (id) values ('a1111111-1111-1111-1111-111111111111'), ('b2222222-2222-2222-2222-222222222222');
insert into public.notebooks (id,user_id,title,started_at) values
 ('a1111111-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111','A',now()),
 ('b2222222-0000-0000-0000-000000000002','b2222222-2222-2222-2222-222222222222','B',now());
insert into public.journal_entries(id,user_id,notebook_id,text,created_at) values
 ('a1111111-0000-0000-0000-000000000011','a1111111-1111-1111-1111-111111111111','a1111111-0000-0000-0000-000000000001','I planted basil',now()),
 ('b2222222-0000-0000-0000-000000000022','b2222222-2222-2222-2222-222222222222','b2222222-0000-0000-0000-000000000002','B secret',now());
update public.journal_entries set context_text = 'I planted [redacted]' where id = 'a1111111-0000-0000-0000-000000000011';
select set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
set local role authenticated;
select is(jsonb_array_length(public.memory_passage_candidates('planted')),1,'caller sees own entry without a graph');
select is(public.memory_passage_candidates('planted')->0->>'text','I planted [redacted]','uses current context projection');
select is(jsonb_array_length(public.memory_passage_candidates('', array['b2222222-0000-0000-0000-000000000022']::uuid[],true)),0,'source suggestions cannot cross accounts');
select is(jsonb_array_length(public.memory_passage_candidates('', array['a1111111-0000-0000-0000-000000000011']::uuid[],true)),1,'eligible suggested source returned');
reset role;
update public.journal_entries set text = 'edited words' where id = 'a1111111-0000-0000-0000-000000000011';
set local role authenticated;
select is(public.memory_passage_candidates('', array['a1111111-0000-0000-0000-000000000011']::uuid[],true)->0->>'text','edited words','exact reread reflects edit');
reset role;
delete from public.journal_entries where id = 'a1111111-0000-0000-0000-000000000011';
set local role authenticated;
select is(jsonb_array_length(public.memory_passage_candidates('', array['a1111111-0000-0000-0000-000000000011']::uuid[],true)),0,'deleted source cannot be retrieved');
select ok(not has_function_privilege('anon','public.memory_passage_candidates(text,uuid[],boolean)','execute'),'anonymous execution denied');
select * from finish();
rollback;
