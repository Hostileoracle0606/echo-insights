-- pgTAP: LM-102 - one vector row per (notebook, entity): the primary key makes a
-- duplicate impossible, and an insert that ignores duplicates leaves the first
-- stored vector in place.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(4);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into public.notebooks (id, user_id, title, summary, started_at, revision) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N1', 'S', now(), 1);

select col_is_pk('public', 'entity_embeddings', array['notebook_id', 'entity_id'],
  'entity_embeddings is keyed (notebook_id, entity_id)');

insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
values ('a1111111-0000-0000-0000-000000000001', 'maya', '11111111-1111-1111-1111-111111111111',
        (select array_fill(0.1::real, array[384])::vector), 'stub@1', 'h1');

select throws_ok(
  $$insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
    values ('a1111111-0000-0000-0000-000000000001', 'maya', '11111111-1111-1111-1111-111111111111',
            (select array_fill(0.9::real, array[384])::vector), 'stub@1', 'h1')$$,
  '23505', null, 'a duplicate row for one entity cannot exist');

insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
values ('a1111111-0000-0000-0000-000000000001', 'maya', '11111111-1111-1111-1111-111111111111',
        (select array_fill(0.9::real, array[384])::vector), 'stub@1', 'h1')
on conflict do nothing;

select is((select count(*)::int from public.entity_embeddings), 1, 'still one row after an ignored duplicate write');
select is((select (embedding::real[])[1] from public.entity_embeddings), 0.1::real, 'the first stored vector is unchanged');

select * from finish();
rollback;
