-- pgTAP: the residual Forget gaps from the re-review (R1, R2, R3, R6).
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(28);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333'),
  ('44444444-4444-4444-4444-444444444444');

insert into public.notebooks (id, user_id, title, summary, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N', 'S', now(), 3, 'just_talk'),
  ('b2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'N', 'S', now(), 3, 'just_talk'),
  ('c3333333-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'N', 'S', now(), 3, 'just_talk'),
  ('d4444444-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'Holds her', 'S', now(), 3, 'just_talk'),
  ('d4444444-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444', 'Stale', 'S', now(), 3, 'just_talk');

insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen) values
  ('maya-chen', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Maya Chen', 'person', null, '{}', null, 1, now(), now()),
  ('ravi', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Ravi', 'person', null,
   '{"type":"Maya Chen colleague","kind":"Maya Chen","mode":"Maya Chen","id":"Maya Chen","nested":{"type":"Maya Chen"}}', null, 1, now(), now()),
  ('jean-claude-van-damme', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Jean-Claude Van Damme', 'person', null, '{}', null, 1, now(), now()),
  ('priya-ramesh-kumar-iyer', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Priya Ramesh Kumar Iyer', 'person', null, '{}', null, 1, now(), now()),
  ('sam', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Sam', 'person',
   'Saw Priya Ramesh Kumar Iyer and Jean-Claude Van Damme.', '{}', null, 1, now(), now()),
  ('андреи', '33333333-3333-3333-3333-333333333333', 'c3333333-0000-0000-0000-000000000001', 'Андрей', 'person', null, '{}', null, 1, now(), now()),
  ('nguyen', '33333333-3333-3333-3333-333333333333', 'c3333333-0000-0000-0000-000000000001', 'Nguyễn', 'person', null, '{}', null, 1, now(), now()),
  (normalize('김민수', NFKD), '33333333-3333-3333-3333-333333333333', 'c3333333-0000-0000-0000-000000000001', '김민수', 'person', null, '{}', null, 1, now(), now()),
  ('lee', '33333333-3333-3333-3333-333333333333', 'c3333333-0000-0000-0000-000000000001', 'Lee', 'person', null, '{}', null, 1, now(), now()),
  ('priya', '44444444-4444-4444-4444-444444444444', 'd4444444-0000-0000-0000-000000000001', 'Priya', 'person', null, '{}', null, 1, now(), now());

insert into public.relations (id, user_id, notebook_id, source_id, target_id, label, metadata) values
  ('ravi__knows__ravi', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'ravi', 'ravi', 'knows', '{"type":"via Maya Chen"}');
insert into public.follow_ups (user_id, notebook_id, question, reason) values
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'How is Priya Ramesh Kumar Iyer?', '');
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('b2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'just_talk', 3,
   '{"title":"T","summary":"With Jean-Claude Van Damme.","notes":[],"remember":[]}'),
  -- nothing in these names her: one current, one stale
  ('d4444444-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'just_talk', 3,
   '{"title":"T","summary":"A quiet day.","notes":[],"remember":[],"sourceRevision":3}'),
  ('d4444444-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444', 'just_talk', 2,
   '{"title":"T","summary":"Older.","notes":[],"remember":[],"sourceRevision":2}');

set local role authenticated;

-- ── R1: metadata is free-form, so no key is structural inside it ───────────
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.forget_entity('maya-chen');

select is((select metadata from public.entities where id = 'ravi'),
  '{"type":"someone colleague","kind":"someone","mode":"someone","id":"someone","nested":{"type":"someone"}}'::jsonb,
  'forget: every string in entity metadata, whatever its key');
select is((select metadata->>'type' from public.relations where id = 'ravi__knows__ravi'),
  'via someone', 'forget: relation metadata under a structural-looking key');

select is(public.commit_notebook(
    'a1111111-0000-0000-0000-000000000001'::uuid,
    (select revision from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'), gen_random_uuid(),
    jsonb_build_object('kind', 'applyTurn', 'entry', jsonb_build_object('text', 'x'),
      'entities', jsonb_build_array(jsonb_build_object('id', 'ravi', 'name', 'Ravi', 'type', 'person', 'mentions', 1,
        'metadata', '{"id":"Maya Chen","kind":"Maya Chen","type":"Maya Chen''s friend"}'::jsonb)),
      'relations', jsonb_build_array(jsonb_build_object('id', 'ravi__met__ravi', 'source', 'ravi', 'target', 'ravi', 'label', 'met',
        'metadata', '{"mode":"Maya Chen"}'::jsonb))))->>'status',
  'committed', 'commit: goes through');
select is((select metadata from public.entities where id = 'ravi'),
  '{"id":"someone","kind":"someone","type":"someone''s friend"}'::jsonb, 'commit: entity metadata, whatever its key');
select is((select metadata->>'mode' from public.relations where id = 'ravi__met__ravi'),
  'someone', 'commit: relation metadata, whatever its key');
select is((select type from public.entities where id = 'ravi'), 'person', 'commit: the entity''s own type is structural');

-- ── R2: names of four words and more ───────────────────────────────────────
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is((public.forget_entity_preview('jean-claude-van-damme')->>'cards'), '1', 'preview: a card naming a 4-token name');
select is((public.forget_entity_preview('priya-ramesh-kumar-iyer')->>'followUps'), '1', 'preview: a question naming a 4-word name');
select public.forget_entity('jean-claude-van-damme');
select public.forget_entity('priya-ramesh-kumar-iyer');

select is(public.redact_forgotten_text('I met Jean-Claude Van Damme today'), 'I met someone today', 'hyphen makes four tokens');
select is(public.redact_forgotten_text('Priya Ramesh Kumar Iyer called'), 'someone called', 'four words');
select is(public.redact_forgotten_text('Priya Ramesh Kumar came by'), 'Priya Ramesh Kumar came by', 'part of a name is not the name');
select is((select description from public.entities where id = 'sam'), 'Saw someone and someone.', 'other entities'' text');
select is((select count(*) from public.follow_ups where user_id = '22222222-2222-2222-2222-222222222222'), 0::bigint, 'the question goes');
select is((select card->>'summary' from public.session_cards where notebook_id = 'b2222222-0000-0000-0000-000000000001'),
  'With someone.', 'the card');

-- ── R3: a client whose slug differs can't recreate them ────────────────────
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select public.forget_entity('андреи');
select public.forget_entity('nguyen');
select public.forget_entity(normalize('김민수', NFKD));

create temp table r as select public.commit_notebook(
  'c3333333-0000-0000-0000-000000000001'::uuid,
  (select revision from public.notebooks where id = 'c3333333-0000-0000-0000-000000000001'), gen_random_uuid(),
  jsonb_build_object('kind', 'applyTurn',
    'entry', jsonb_build_object('text', 'x', 'entityIds', '["андрей","nguy-n","김민수","lee"]'::jsonb,
                                'relationIds', '["lee__knows__андрей"]'::jsonb),
    'entities', jsonb_build_array(
      jsonb_build_object('id', 'андрей', 'name', 'Андрей', 'type', 'person', 'mentions', 1),
      jsonb_build_object('id', 'nguy-n', 'name', 'Nguyễn', 'type', 'person', 'mentions', 1),
      jsonb_build_object('id', '김민수', 'name', '김민수', 'type', 'person', 'mentions', 1),
      jsonb_build_object('id', 'lee', 'name', 'Lee', 'type', 'person', 'mentions', 2)),
    'relations', jsonb_build_array(
      jsonb_build_object('id', 'lee__knows__андрей', 'source', 'lee', 'target', 'андрей', 'label', 'knows')))) as res;

select is((select res->>'status' from r), 'committed', 'the turn still commits');
select is((select count(*) from public.entities where user_id = '33333333-3333-3333-3333-333333333333' and id <> 'lee'),
  0::bigint, 'none of the three is recreated');
select is((select count(*) from public.entities where name = 'someone'), 0::bigint, 'and no entity called someone');
select is((select mentions from public.entities where id = 'lee'), 2, 'the bystander is updated');
select is((select count(*) from public.relations where id = 'lee__knows__андрей'), 0::bigint, 'a relation to them is dropped');
select is((select entity_ids from public.journal_entries where user_id = '33333333-3333-3333-3333-333333333333'),
  array['lee'], 'and their ids leave the entry');
select ok((select res->'suppressedIds' @> '["андрей","nguy-n","김민수"]'::jsonb from r), 'the device is told');
select is(public.commit_notebook(
    'c3333333-0000-0000-0000-000000000001'::uuid,
    (select revision from public.notebooks where id = 'c3333333-0000-0000-0000-000000000001'), gen_random_uuid(),
    jsonb_build_object('kind', 'applyTurn', 'entry', jsonb_build_object('text', 'x'),
      'entities', jsonb_build_array(jsonb_build_object('id', 'андрей', 'name', 'Андрюша', 'type', 'person', 'mentions', 1))))->'suppressedIds',
  '["андрей"]'::jsonb, 'that id stays out, under any name');

-- ── R6: a card that was current stays current ──────────────────────────────
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select public.forget_entity('priya');

select is((select revision from public.notebooks where id = 'd4444444-0000-0000-0000-000000000001'),
  4::bigint, 'the notebook moved on');
select is((select source_revision from public.session_cards where notebook_id = 'd4444444-0000-0000-0000-000000000001'),
  4::bigint, 'a current card with no mention moves with it');
select is((select card->'sourceRevision' from public.session_cards where notebook_id = 'd4444444-0000-0000-0000-000000000001'),
  '4'::jsonb, 'in the card too');
select is((select card->>'summary' from public.session_cards where notebook_id = 'd4444444-0000-0000-0000-000000000001'),
  'A quiet day.', 'unchanged otherwise');
select is((select source_revision from public.session_cards where notebook_id = 'd4444444-0000-0000-0000-000000000002'),
  2::bigint, 'a stale card stays stale');
select is((select card->'sourceRevision' from public.session_cards where notebook_id = 'd4444444-0000-0000-0000-000000000002'),
  '2'::jsonb, 'in the card too');

select * from finish();
rollback;
