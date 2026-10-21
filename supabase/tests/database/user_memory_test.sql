-- pgTAP tests for the user-wide memory read model (LM-06): user_entities,
-- user_relations, get_user_graph, get_entity_mentions and
-- match_user_entity_embeddings.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(43);

-- ── fixtures (default role, so RLS doesn't apply while seeding) ────────────
-- User A: notebooks n1..n3 all mention priya, n4 only ci.
-- User B: their own priya, which A must never see.
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into public.notebooks (id, user_id, title, started_at) values
  ('a0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'January', '2026-01-01T09:00:00Z'),
  ('a0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'February', '2026-02-01T09:00:00Z'),
  ('a0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'March', '2026-03-01T09:00:00Z'),
  ('a0000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Build', '2026-04-01T09:00:00Z'),
  ('b0000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'B notebook', '2026-01-01T09:00:00Z');

insert into public.entities (id, user_id, notebook_id, name, type, description, mentions, first_seen, last_seen) values
  -- priya: the latest row (n3) has no description, so the latest non-null one is n2's.
  ('priya', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000001', 'Priya', 'other', 'A friend from school', 2, '2026-01-01T10:00:00Z', '2026-01-05T10:00:00Z'),
  ('priya', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000002', 'Priya S', 'other', 'Leads the Atlas team', 3, '2026-02-01T10:00:00Z', '2026-02-05T10:00:00Z'),
  ('priya', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000003', 'Priya Sharma', 'person', null, 4, '2026-03-01T10:00:00Z', '2026-03-05T10:00:00Z'),
  ('atlas', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000001', 'Atlas', 'project', 'The new platform', 5, '2026-01-02T10:00:00Z', '2026-01-04T10:00:00Z'),
  ('maya',  '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000002', 'Maya', 'person', 'Mentor', 7, '2026-02-02T10:00:00Z', '2026-02-04T10:00:00Z'),
  ('ci',    '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000004', 'CI', 'project', 'Build pipeline', 1, '2026-04-01T10:00:00Z', '2026-04-01T10:00:00Z'),
  ('priya', '22222222-2222-2222-2222-222222222222', 'b0000000-0000-0000-0000-000000000001', 'Priya B', 'person', 'B''s Priya', 1, '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z');

insert into public.relations (id, user_id, notebook_id, source_id, target_id, label, created_at, superseded_at) values
  -- Only ever stated once: active.
  ('priya__works_on__atlas', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000001', 'priya', 'atlas', 'works_on', '2026-01-02T10:00:00Z', null),
  -- Stated in n1, contradicted in the later n2: inactive, even though n1's row is unsuperseded.
  ('maya__knows__priya', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000001', 'maya', 'priya', 'knows', '2026-01-03T10:00:00Z', null),
  ('maya__knows__priya', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000002', 'maya', 'priya', 'knows', '2026-02-02T10:00:00Z', '2026-02-03T10:00:00Z'),
  -- Stated in n1, contradicted in n2, re-stated in n3 after the contradiction: active again.
  ('priya__leads__ci', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000001', 'priya', 'ci', 'leads', '2026-01-04T10:00:00Z', null),
  ('priya__leads__ci', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000002', 'priya', 'ci', 'leads', '2026-02-02T10:00:00Z', '2026-02-10T10:00:00Z'),
  ('priya__leads__ci', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000003', 'priya', 'ci', 'leads', '2026-03-02T10:00:00Z', null),
  ('maya__mentors__priya', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000002', 'maya', 'priya', 'mentors', '2026-02-04T10:00:00Z', null),
  ('priya__knows__sam', '22222222-2222-2222-2222-222222222222', 'b0000000-0000-0000-0000-000000000001', 'priya', 'sam', 'knows', '2026-01-01T10:00:00Z', null);

insert into public.journal_entries (id, user_id, notebook_id, text, created_at, entity_ids) values
  ('e0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000001', 'I had lunch with Priya.', '2026-01-02T10:00:00Z', array['priya', 'atlas']),
  ('e0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000002', 'Priya is leading Atlas now.', '2026-02-02T10:00:00Z', array['priya']),
  ('e0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000003', 'Priya got promoted.', '2026-03-02T10:00:00Z', array['priya']),
  ('e0000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000003', 'Priya ' || repeat('x', 400), '2026-03-03T10:00:00Z', array['priya', 'maya']),
  ('e0000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000004', 'CI is flaky.', '2026-04-01T10:00:00Z', array['ci']),
  ('e0000000-0000-0000-0000-000000000006', '22222222-2222-2222-2222-222222222222', 'b0000000-0000-0000-0000-000000000001', 'Priya B said hi.', '2026-01-01T10:00:00Z', array['priya']);

insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at) values
  -- e1's text was said three times; t1 is the latest at or before the entry was committed.
  ('a0000000-0000-0000-0000-000000000001', 't0', '11111111-1111-1111-1111-111111111111', 'user', 'I had lunch with Priya.', '2026-01-02T09:00:00Z'),
  ('a0000000-0000-0000-0000-000000000001', 't1', '11111111-1111-1111-1111-111111111111', 'user', 'I had lunch with Priya.', '2026-01-02T09:59:00Z'),
  ('a0000000-0000-0000-0000-000000000001', 't2', '11111111-1111-1111-1111-111111111111', 'user', 'I had lunch with Priya.', '2026-01-02T10:05:00Z'),
  -- e2: the text differs (case), so no match.
  ('a0000000-0000-0000-0000-000000000002', 't3', '11111111-1111-1111-1111-111111111111', 'user', 'priya is leading atlas now', '2026-02-02T09:59:00Z'),
  -- e3: same text but said by Lumen, so no match.
  ('a0000000-0000-0000-0000-000000000003', 't4', '11111111-1111-1111-1111-111111111111', 'assistant', 'Priya got promoted.', '2026-03-02T09:59:00Z');

-- One-hot 384-d vectors for the embedding match.
create temporary table vecs on commit drop as
select
  (select array_agg(case when i = 1 then 1 else 0 end)::real[] from generate_series(1, 384) i)::vector(384) as x,
  (select array_agg(case when i = 2 then 1 else 0 end)::real[] from generate_series(1, 384) i)::vector(384) as y,
  (select array_agg(case when i <= 2 then 1 else 0 end)::real[] from generate_series(1, 384) i)::vector(384) as xy;
grant select on vecs to authenticated, service_role;

insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
select n, e, u, v, m, 'h' from vecs, lateral (values
  ('a0000000-0000-0000-0000-000000000001'::uuid, 'priya', '11111111-1111-1111-1111-111111111111'::uuid, vecs.x,  'gte-small'),
  ('a0000000-0000-0000-0000-000000000002'::uuid, 'priya', '11111111-1111-1111-1111-111111111111'::uuid, vecs.y,  'gte-small'),
  ('a0000000-0000-0000-0000-000000000004'::uuid, 'ci',    '11111111-1111-1111-1111-111111111111'::uuid, vecs.xy, 'gte-small'),
  ('a0000000-0000-0000-0000-000000000001'::uuid, 'atlas', '11111111-1111-1111-1111-111111111111'::uuid, vecs.x,  'old-model'),
  ('b0000000-0000-0000-0000-000000000001'::uuid, 'priya', '22222222-2222-2222-2222-222222222222'::uuid, vecs.x,  'gte-small')
) as t(n, e, u, v, m);

-- ── 1. the views run as the caller ─────────────────────────────────────────
select ok(
  (select reloptions @> array['security_invoker=true'] from pg_class where oid = 'public.user_entities'::regclass),
  'user_entities is security_invoker (otherwise it would bypass RLS)');
select ok(
  (select reloptions @> array['security_invoker=true'] from pg_class where oid = 'public.user_relations'::regclass),
  'user_relations is security_invoker (otherwise it would bypass RLS)');

-- ── 2. user_entities as A ───────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select is((select count(*)::int from public.user_entities), 4, 'A sees one row per entity slug, none of B''s');
select is((select mentions from public.user_entities where id = 'priya'), 9, 'priya mentions are summed across notebooks');
select is((select notebook_count from public.user_entities where id = 'priya'), 3, 'priya appears in 3 notebooks');
select is(
  (select notebook_ids from public.user_entities where id = 'priya'),
  array['a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000003']::uuid[],
  'notebook_ids lists the notebooks, oldest first');
select is((select name from public.user_entities where id = 'priya'), 'Priya Sharma', 'name comes from the latest-seen row');
select is((select type from public.user_entities where id = 'priya'), 'person', 'type comes from the latest-seen row');
select is((select description from public.user_entities where id = 'priya'), 'Leads the Atlas team', 'description is the latest non-null one');
select is((select first_seen from public.user_entities where id = 'priya'), '2026-01-01T10:00:00Z'::timestamptz, 'first_seen is the earliest');
select is((select last_seen from public.user_entities where id = 'priya'), '2026-03-05T10:00:00Z'::timestamptz, 'last_seen is the latest');

-- ── 3. user_relations as A ──────────────────────────────────────────────────
select is((select count(*)::int from public.user_relations), 4, 'A sees one row per relation id, none of B''s');
select is((select active from public.user_relations where id = 'priya__works_on__atlas'), true, 'a relation stated once is active');
select is((select active from public.user_relations where id = 'maya__knows__priya'), false, 'a relation contradicted in a later notebook is inactive');
select is((select active from public.user_relations where id = 'priya__leads__ci'), true, 'a relation re-stated after its contradiction is active again');
select is((select notebook_count from (select cardinality(notebook_ids) as notebook_count from public.user_relations where id = 'priya__leads__ci') s), 3, 'notebook_ids covers every notebook holding the relation');
select is((select first_created_at from public.user_relations where id = 'priya__leads__ci'), '2026-01-04T10:00:00Z'::timestamptz, 'first_created_at is the earliest');
select is(
  (select array[source_id, target_id, label] from public.user_relations where id = 'maya__mentors__priya'),
  array['maya', 'priya', 'mentors'],
  'source, target and label are carried through');

-- ── 4. get_user_graph ───────────────────────────────────────────────────────
select is(
  (select public.get_user_graph()) - 'entities' - 'relations',
  '{"entityCount": 4, "relationCount": 3}'::jsonb,
  'graph totals: 4 entities and 3 active relations');
select is(
  (select array_agg(e ->> 'id' order by ord) from jsonb_array_elements(public.get_user_graph() -> 'entities') with ordinality as t(e, ord)),
  array['priya', 'maya', 'atlas', 'ci'],
  'entities are ordered by mentions');
select is(
  (select public.get_user_graph() -> 'entities' -> 0),
  '{"id": "priya", "name": "Priya Sharma", "type": "person", "description": "Leads the Atlas team", "mentions": 9,
    "firstSeen": "2026-01-01T10:00:00+00:00", "lastSeen": "2026-03-05T10:00:00+00:00", "notebookCount": 3}'::jsonb,
  'an entity has the documented camelCase shape');
select is(
  (select array_agg(r ->> 'id' order by r ->> 'id') from jsonb_array_elements(public.get_user_graph() -> 'relations') r),
  array['maya__mentors__priya', 'priya__leads__ci', 'priya__works_on__atlas'],
  'only active relations are returned');
select is(
  (select public.get_user_graph() -> 'relations' -> 0),
  '{"id": "maya__mentors__priya", "source": "maya", "target": "priya", "label": "mentors"}'::jsonb,
  'a relation has the documented shape');

select is(
  (select array_agg(e ->> 'id' order by ord) from jsonb_array_elements(public.get_user_graph(null, 2) -> 'entities') with ordinality as t(e, ord)),
  array['priya', 'maya'],
  'p_limit keeps the top entities by mentions');
select is(
  (select array_agg(r ->> 'id') from jsonb_array_elements(public.get_user_graph(null, 2) -> 'relations') r),
  array['maya__mentors__priya'],
  'relations are restricted to the returned entities');
select is(
  (select public.get_user_graph(null, 2)) - 'entities' - 'relations',
  '{"entityCount": 4, "relationCount": 3}'::jsonb,
  'totals are counted before the limit');
select is(
  (select jsonb_array_length(public.get_user_graph(null, 0) -> 'entities')),
  1,
  'p_limit is clamped to at least 1');

select is(
  (select array_agg(e ->> 'id' order by ord) from jsonb_array_elements(public.get_user_graph(array['project']) -> 'entities') with ordinality as t(e, ord)),
  array['atlas', 'ci'],
  'p_types filters entities by type');
select is(
  (select public.get_user_graph(array['project'])) - 'entities',
  '{"entityCount": 2, "relationCount": 0, "relations": []}'::jsonb,
  'type-filtered totals and relations only cover the filtered entities');

-- ── 5. get_entity_mentions ──────────────────────────────────────────────────
select is(
  (select (public.get_entity_mentions('priya') ->> 'total')::int),
  4,
  'total counts A''s entries that mention priya (not B''s)');
select is(
  (select array_agg(m ->> 'entryId' order by ord) from jsonb_array_elements(public.get_entity_mentions('priya') -> 'mentions') with ordinality as t(m, ord)),
  array['e0000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000003',
        'e0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001'],
  'mentions are newest first');
select is(
  (select array_agg(m ->> 'entryId' order by ord) from jsonb_array_elements(public.get_entity_mentions('priya', 2) -> 'mentions') with ordinality as t(m, ord)),
  array['e0000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000003'],
  'p_limit takes the newest page');
select is(
  (select array_agg(m ->> 'entryId' order by ord) from jsonb_array_elements(public.get_entity_mentions('priya', 2, '2026-03-02T10:00:00Z') -> 'mentions') with ordinality as t(m, ord)),
  array['e0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001'],
  'p_before pages to older mentions');
select is(
  (select (public.get_entity_mentions('priya', 2, '2026-03-02T10:00:00Z') ->> 'total')::int),
  4,
  'total ignores paging');
select is(
  (select char_length(public.get_entity_mentions('priya') -> 'mentions' -> 0 ->> 'excerpt')),
  280,
  'excerpt is the first 280 characters');
select is(
  (select m - 'excerpt' from jsonb_array_elements(public.get_entity_mentions('priya') -> 'mentions') m
   where m ->> 'entryId' = 'e0000000-0000-0000-0000-000000000001'),
  '{"entryId": "e0000000-0000-0000-0000-000000000001", "notebookId": "a0000000-0000-0000-0000-000000000001",
    "notebookTitle": "January", "notebookStartedAt": "2026-01-01T09:00:00+00:00",
    "conversationMode": "just_talk",
    "createdAt": "2026-01-02T10:00:00+00:00", "turnId": "t1", "spokenAt": "2026-01-02T09:59:00+00:00"}'::jsonb,
  'a matching user turn is the latest one spoken at or before the entry');
select is(
  (select array_agg(coalesce(m ->> 'turnId', 'null') order by m ->> 'entryId')
   from jsonb_array_elements(public.get_entity_mentions('priya') -> 'mentions') m
   where m ->> 'entryId' in ('e0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000003')),
  array['null', 'null'],
  'turnId is null when no user turn has the same text');

-- ── 6. RLS from B's side, and anon ──────────────────────────────────────────
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(
  (select array_agg(array[id, name, mentions::text]) from public.user_entities),
  array[array['priya', 'Priya B', '1']],
  'B sees only their own priya');
select is(
  (select (public.get_entity_mentions('priya') ->> 'total')::int),
  1,
  'B''s mentions are only B''s entries');

reset role;
set local role anon;
select throws_ok('select * from public.user_entities', '42501', null, 'anon cannot read user_entities');
select throws_ok('select * from public.user_relations', '42501', null, 'anon cannot read user_relations');

-- ── 7. match_user_entity_embeddings is service-role only ────────────────────
reset role;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select throws_ok(
  $$select * from public.match_user_entity_embeddings('11111111-1111-1111-1111-111111111111', (select x from vecs), 10, 'gte-small')$$,
  '42501', null, 'authenticated cannot call match_user_entity_embeddings');

reset role;
set local role service_role;
select results_eq(
  $$select entity_id, notebook_id, round(score::numeric, 3)
    from public.match_user_entity_embeddings('11111111-1111-1111-1111-111111111111', (select x from vecs), 10, 'gte-small')$$,
  $$values ('priya'::text, 'a0000000-0000-0000-0000-000000000001'::uuid, 1.000::numeric),
           ('ci'::text,    'a0000000-0000-0000-0000-000000000004'::uuid, 0.707::numeric)$$,
  'service role: best score per entity across the user''s notebooks, model-filtered, other users excluded');

select * from finish();
rollback;
