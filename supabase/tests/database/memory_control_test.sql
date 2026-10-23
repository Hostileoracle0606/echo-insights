-- pgTAP tests for memory control (LM-29): edit_entity_description,
-- remove_entity, suppression inside commit_notebook, and the snapshot fields.
-- Run: supabase test db
--
-- Two users share the slugs "priya" and "maya", so every RPC is checked
-- against a neighbour's identical rows: remove_entity is SECURITY DEFINER and
-- one missing user filter would delete someone else's memory.
create extension if not exists pgtap;

begin;
select plan(48);

-- ── fixtures (default role, so RLS doesn't apply while seeding) ────────────
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

-- A owns N1, N2 and an empty N4; B owns N3.
insert into public.notebooks (id, user_id, title, started_at) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N1', now()),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'N2', now()),
  ('a1111111-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'N4', now()),
  ('b2222222-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'N3', now());

insert into public.entities (id, user_id, notebook_id, name, type, description, mentions, first_seen, last_seen) values
  ('priya', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Priya', 'person', 'A friend.', 2, now(), now()),
  ('maya',  '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Maya',  'person', 'Old maya text.', 1, now(), now()),
  ('priya', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Priya', 'person', 'A friend.', 1, now(), now()),
  ('maya',  '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Maya',  'person', 'Older maya text.', 1, now(), now()),
  ('atlas', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Atlas', 'project', 'A project.', 1, now(), now()),
  ('ravi',  '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Ravi',  'person', null, 1, now(), now()),
  ('priya', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'Priya', 'person', 'B''s Priya.', 1, now(), now()),
  ('maya',  '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'Maya',  'person', 'B''s Maya.', 1, now(), now());

insert into public.relations (id, user_id, notebook_id, source_id, target_id, label) values
  ('priya__friend_of__maya', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'priya', 'maya', 'friend_of'),
  ('atlas__led_by__priya',   '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'atlas', 'priya', 'led_by'),
  ('maya__works_on__atlas',  '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'maya', 'atlas', 'works_on'),
  ('priya__friend_of__maya', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'priya', 'maya', 'friend_of');

insert into public.journal_entries (user_id, notebook_id, text, created_at, entity_ids, relation_ids) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Priya and Maya.', now(),
   array['priya','maya'], array['priya__friend_of__maya']),
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Priya leads Atlas.', now(),
   array['atlas','priya'], array['atlas__led_by__priya','maya__works_on__atlas']),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'B: Priya and Maya.', now(),
   array['priya','maya'], array['priya__friend_of__maya']);

insert into public.follow_ups (user_id, notebook_id, question, target_entity_ids) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'How is Priya?', array['priya','maya']),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'How is Priya?', array['priya']);

insert into public.asked_questions (user_id, notebook_id, question, target_entity_ids) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Who leads Atlas?', array['priya','atlas']),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000003', 'Who is Priya?', array['priya']);

insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash) values
  ('a1111111-0000-0000-0000-000000000001', 'priya', '11111111-1111-1111-1111-111111111111', array_fill(0.1, array[384])::vector, 'test@1', 'h'),
  ('a1111111-0000-0000-0000-000000000002', 'priya', '11111111-1111-1111-1111-111111111111', array_fill(0.1, array[384])::vector, 'test@1', 'h'),
  ('a1111111-0000-0000-0000-000000000001', 'maya',  '11111111-1111-1111-1111-111111111111', array_fill(0.1, array[384])::vector, 'test@1', 'h'),
  ('b2222222-0000-0000-0000-000000000003', 'priya', '22222222-2222-2222-2222-222222222222', array_fill(0.1, array[384])::vector, 'test@1', 'h');

-- ── 1. anon can call neither RPC ───────────────────────────────────────────
set local role anon;
select throws_ok($$ select public.edit_entity_description('maya', 'x') $$, '42501', null,
  'anon cannot call edit_entity_description');
select throws_ok($$ select public.remove_entity('maya') $$, '42501', null,
  'anon cannot call remove_entity');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── 2. edit_entity_description ─────────────────────────────────────────────
select is(
  public.edit_entity_description('maya', 'My closest friend from college.'),
  '{"updatedNotebooks": 2}'::jsonb,
  'edit: reports both of the caller''s notebooks that hold the id');
select is(
  (select array_agg(distinct description) from public.entities where id = 'maya'
     and user_id = '11111111-1111-1111-1111-111111111111'),
  array['My closest friend from college.'],
  'edit: every one of the caller''s rows gets the text');
select is(
  (select array_agg(distinct description_source) from public.entities where id = 'maya'
     and user_id = '11111111-1111-1111-1111-111111111111'),
  array['user'],
  'edit: every one of the caller''s rows is marked user-written');
select is(
  (select array_agg(revision order by title) from public.notebooks where title in ('N1', 'N2')),
  array[1::bigint, 1::bigint],
  'edit: each affected notebook''s revision is bumped, so an open device reloads');
select is(
  (select revision from public.notebooks where title = 'N4'),
  0::bigint,
  'edit: a notebook without the entity is not bumped');
select lives_ok($$ select public.edit_entity_description('ravi', repeat('x', 900)) $$,
  'edit: an over-long text is accepted');
select is(
  (select length(description) from public.entities where id = 'ravi'),
  800,
  'edit: text is capped at 800 characters, the extractor''s limit');
select throws_ok($$ select public.edit_entity_description('maya', '   ') $$, '22023', null,
  'edit: blank text is rejected');

-- ── 3. a later extraction cannot overwrite the user's text ─────────────────
select revision from public.notebooks where title = 'N1' \gset n1_
select public.commit_notebook(
  'a1111111-0000-0000-0000-000000000001'::uuid, :n1_revision::bigint, 'c0000000-0000-0000-0000-000000000001'::uuid,
  '{"kind":"applyTurn",
    "entry":{"text":"Saw Maya again.","entityIds":["maya"],"relationIds":[]},
    "entities":[{"id":"maya","name":"Maya","type":"person","description":"Extractor rewrite.","metadata":{},"mentions":5,
                 "firstSeen":"2026-10-23T00:00:00Z","lastSeen":"2026-10-23T00:00:00Z"}],
    "relations":[]}'::jsonb
) as edit_turn \gset

select is(:'edit_turn'::jsonb ->> 'status', 'committed', 'kept description: the turn commits');
select is(
  (select description from public.entities where id = 'maya' and notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'My closest friend from college.',
  'kept description: the user''s text survives a new extracted description');
select is(
  (select description_source from public.entities where id = 'maya' and notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'user',
  'kept description: the upsert never changes description_source');
select is(
  (select mentions from public.entities where id = 'maya' and notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  5,
  'kept description: the rest of the row still updates');

-- A brand-new row in a notebook that has never seen Maya inherits the text.
select public.commit_notebook(
  'a1111111-0000-0000-0000-000000000004'::uuid, 0::bigint, 'c0000000-0000-0000-0000-000000000002'::uuid,
  '{"kind":"applyTurn",
    "entry":{"text":"Maya, in a new conversation.","entityIds":["maya"],"relationIds":[]},
    "entities":[{"id":"maya","name":"Maya","type":"person","description":"Fresh extraction.","metadata":{},"mentions":1,
                 "firstSeen":"2026-10-23T00:00:00Z","lastSeen":"2026-10-23T00:00:00Z"}],
    "relations":[]}'::jsonb
) as inherit_turn \gset

select is(:'inherit_turn'::jsonb ->> 'status', 'committed', 'inherit: the first turn in a new notebook commits');
select is(
  (select description from public.entities where id = 'maya' and notebook_id = 'a1111111-0000-0000-0000-000000000004'),
  'My closest friend from college.',
  'inherit: a new notebook''s first row copies the user''s description');
select is(
  (select description_source from public.entities where id = 'maya' and notebook_id = 'a1111111-0000-0000-0000-000000000004'),
  'user',
  'inherit: and is marked user-written');

-- ── 4. snapshot fields ─────────────────────────────────────────────────────
select is(
  public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000002'::uuid) #>> '{state,entities,maya,descriptionSource}',
  'user',
  'snapshot: entities carry descriptionSource (user)');
select is(
  public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000002'::uuid) #>> '{state,entities,atlas,descriptionSource}',
  'extracted',
  'snapshot: entities carry descriptionSource (extracted)');
select is(
  public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000002'::uuid) -> 'suppressedEntityIds',
  '[]'::jsonb,
  'snapshot: suppressedEntityIds is an empty array before any removal');

-- ── 5. another user cannot edit A's rows ───────────────────────────────────
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(
  public.edit_entity_description('atlas', 'B was here.'),
  '{"updatedNotebooks": 0}'::jsonb,
  'edit: an id the caller does not own updates nothing');
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(
  (select description from public.entities where id = 'atlas'),
  'A project.',
  'edit: the owner''s row is untouched by another user''s call');

-- ── 6. remove_entity ───────────────────────────────────────────────────────
select revision from public.notebooks where title = 'N1' \gset pre_n1_
select revision from public.notebooks where title = 'N2' \gset pre_n2_

select is(
  public.remove_entity('priya'),
  '{"removedFrom": 2}'::jsonb,
  'remove: reports the number of notebooks it was removed from');
select is(
  (select count(*)::int from public.entities where id = 'priya' and user_id = '11111111-1111-1111-1111-111111111111'),
  0,
  'remove: the entity is gone from every one of the caller''s notebooks');
select is(
  (select count(*)::int from public.relations
     where user_id = '11111111-1111-1111-1111-111111111111' and 'priya' in (source_id, target_id)),
  0,
  'remove: relations with it as source or target are gone');
select is(
  (select count(*)::int from public.relations where id = 'maya__works_on__atlas'),
  1,
  'remove: unrelated relations stay');
-- entity_embeddings has no client access at all; check it as the owner role.
reset role;
select is(
  (select count(*)::int from public.entity_embeddings
     where entity_id = 'priya' and user_id = '11111111-1111-1111-1111-111111111111'),
  0,
  'remove: its embeddings are gone');
select is(
  (select count(*)::int from public.entity_embeddings where entity_id = 'maya'),
  1,
  'remove: other entities'' embeddings stay');
set local role authenticated;
select is(
  (select array_agg(array_to_string(entity_ids, ',') || '|' || array_to_string(relation_ids, ',') order by text)
     from public.journal_entries where user_id = '11111111-1111-1111-1111-111111111111'
       and notebook_id <> 'a1111111-0000-0000-0000-000000000004'),
  array['maya|', 'atlas|maya__works_on__atlas', 'maya|'],
  'remove: entries lose the entity id and the deleted relation ids, nothing else');
select is(
  (select target_entity_ids from public.follow_ups where user_id = '11111111-1111-1111-1111-111111111111'),
  array['maya'],
  'remove: follow-ups lose the id');
select is(
  (select target_entity_ids from public.asked_questions where user_id = '11111111-1111-1111-1111-111111111111'),
  array['atlas'],
  'remove: asked questions lose the id');
select is(
  (select array_agg(entity_count order by title) from public.notebooks where title in ('N1', 'N2')),
  array[1, 3],
  'remove: entity_count is recomputed on each affected notebook');
select is(
  (select array_agg(revision order by title) from public.notebooks where title in ('N1', 'N2')),
  array[:pre_n1_revision::bigint + 1, :pre_n2_revision::bigint + 1],
  'remove: revision is bumped on each affected notebook');
select is(
  (select array_agg(entity_id) from public.entity_suppressions),
  array['priya'],
  'remove: the owner can read their suppression row');
select throws_ok($$
  insert into public.entity_suppressions (user_id, entity_id)
  values ('11111111-1111-1111-1111-111111111111', 'maya')
$$, '42501', null, 'suppressions are written only through the RPC');
select is(
  public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000001'::uuid) -> 'suppressedEntityIds',
  '["priya"]'::jsonb,
  'snapshot: suppressedEntityIds lists the removed id');

-- ── 7. a later turn cannot bring the entity back ───────────────────────────
select revision from public.notebooks where title = 'N1' \gset back_
select public.commit_notebook(
  'a1111111-0000-0000-0000-000000000001'::uuid, :back_revision::bigint, 'c0000000-0000-0000-0000-000000000003'::uuid,
  '{"kind":"applyTurn",
    "entry":{"text":"Priya called Maya.","entityIds":["priya","maya"],"relationIds":["priya__called__maya"]},
    "entities":[
      {"id":"priya","name":"Priya","type":"person","description":"Back again?","metadata":{},"mentions":1,
       "firstSeen":"2026-10-23T00:00:00Z","lastSeen":"2026-10-23T00:00:00Z"},
      {"id":"maya","name":"Maya","type":"person","metadata":{},"mentions":6,
       "firstSeen":"2026-10-23T00:00:00Z","lastSeen":"2026-10-23T00:00:00Z"}],
    "relations":[{"id":"priya__called__maya","source":"priya","target":"maya","label":"called","metadata":{},
                  "createdAt":"2026-10-23T00:00:00Z"}]}'::jsonb
) as back_turn \gset

select is(:'back_turn'::jsonb ->> 'status', 'committed', 'suppressed: a turn mentioning the removed entity still commits');
select is(
  (select count(*)::int from public.entities where id = 'priya' and user_id = '11111111-1111-1111-1111-111111111111'),
  0,
  'suppressed: the entity is not stored');
select is(
  (select count(*)::int from public.relations where id = 'priya__called__maya'),
  0,
  'suppressed: a relation to it is not stored');
select is(
  (select array_to_string(entity_ids, ',') || '|' || array_to_string(relation_ids, ',')
     from public.journal_entries where text = 'Priya called Maya.'),
  'maya|',
  'suppressed: the entry keeps only the surviving ids');
select is(
  (select mentions from public.entities where id = 'maya' and notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  6,
  'suppressed: the rest of the turn is applied');

-- ── 8. the other user's identical slug is untouched ────────────────────────
reset role;
select is(
  (select count(*)::int from public.entities where user_id = '22222222-2222-2222-2222-222222222222'),
  2,
  'neighbour: B''s entities (same slugs) are untouched');
select is(
  (select description_source from public.entities where user_id = '22222222-2222-2222-2222-222222222222' and id = 'maya'),
  'extracted',
  'neighbour: B''s Maya keeps its extracted description');
select is(
  (select count(*)::int from public.relations where user_id = '22222222-2222-2222-2222-222222222222'),
  1,
  'neighbour: B''s relation is untouched');
select is(
  (select count(*)::int from public.entity_embeddings where user_id = '22222222-2222-2222-2222-222222222222'),
  1,
  'neighbour: B''s embedding is untouched');
select is(
  (select array_to_string(entity_ids, ',') from public.journal_entries where user_id = '22222222-2222-2222-2222-222222222222'),
  'priya,maya',
  'neighbour: B''s entries still reference Priya');
select is(
  (select count(*)::int from public.entity_suppressions where user_id = '22222222-2222-2222-2222-222222222222'),
  0,
  'neighbour: B has no suppression');

set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(
  (select count(*)::int from public.entity_suppressions),
  0,
  'neighbour: B cannot read A''s suppressions');

select * from finish();
rollback;
