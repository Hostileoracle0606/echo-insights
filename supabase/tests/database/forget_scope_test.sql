-- pgTAP: what Forget touches, and what it must leave alone (final review C1,
-- C2, I3, I4, M2). Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(44);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333');

insert into public.notebooks (id, user_id, title, summary, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Work', 'Back to work', now(), 3, 'just_talk'),
  ('b2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'N', 'S', now(), 3, 'just_talk'),
  ('b2222222-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'M', 'S', now(), 3, 'just_talk'),
  ('c3333333-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'N', 'S', now(), 3, 'just_talk');

insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen) values
  ('work',  '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'work',  'concept', null, '{}', null, 1, now(), now()),
  ('talk',  '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'talk',  'concept', null, '{}', null, 1, now(), now()),
  ('will',  '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Will',  'person',  null, '{}', null, 1, now(), now()),
  ('may',   '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'May',   'person',  null, '{}', null, 1, now(), now()),
  ('mark',  '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Mark',  'person',  null, '{}', null, 1, now(), now()),
  ('maya-chen', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Maya Chen', 'person', null, '{}', null, 1, now(), now()),
  ('ravi', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000002', 'Ravi', 'person',
   'Works with Maya Chen.', '{"via":"Maya Chen"}', array['How is Maya Chen?', 'Is he well?'], 1, now(), now()),
  ('e-1730000000000', '33333333-3333-3333-3333-333333333333', 'c3333333-0000-0000-0000-000000000001', 'प्रिया', 'person', null, '{}', null, 1, now(), now()),
  ('иван', '33333333-3333-3333-3333-333333333333', 'c3333333-0000-0000-0000-000000000001', 'Иван', 'person', null, '{}', null, 1, now(), now()),
  ('李雷', '33333333-3333-3333-3333-333333333333', 'c3333333-0000-0000-0000-000000000001', '李雷', 'person', null, '{}', null, 1, now(), now());

insert into public.relations (id, user_id, notebook_id, source_id, target_id, label, metadata) values
  ('ravi__knows__ravi', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000002', 'ravi', 'ravi', 'knows', '{"note":"via Maya Chen"}');
insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
  select notebook_id, id, user_id, array_fill(0.0::real, array[384])::vector, 'm', 'h'
  from public.entities where id = 'ravi';
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'just_talk', 3,
   '{"version":1,"notebookId":"a1111111-0000-0000-0000-000000000001","conversationMode":"just_talk","sourceRevision":3,
     "title":"Work","summary":"Work was fine, then back to work.","remember":[{"entityId":"work-project","name":"Work project"}],
     "notes":["We may mark it. Will said so."]}'),
  ('b2222222-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'just_talk', 3,
   '{"title":"Ravi","summary":"Ravi and Maya Chen.","notes":[],"remember":[]}');

create function public._t_card(p_rev bigint, p_summary text, p_entity text)
returns jsonb language sql as $$
  select jsonb_build_object('version', 1, 'notebookId', 'a1111111-0000-0000-0000-000000000001',
    'conversationMode', 'just_talk', 'sourceRevision', p_rev, 'title', 'T', 'summary', p_summary,
    'remember', jsonb_build_array(jsonb_build_object('entityId', p_entity, 'name', 'N')), 'notes', '[]'::jsonb);
$$;
grant execute on function public._t_card(bigint, text, text) to authenticated;

set local role authenticated;

-- ── C1: Remove is not Forget ───────────────────────────────────────────────
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.remove_entity('work');
select public.remove_entity('talk');

select is(public.redact_forgotten_text('Work was fine, then back to work.'),
  'Work was fine, then back to work.', 'a removed word is not redacted');
select is(public.forget_entity_preview('work')->>'cards', '1', 'preview still works on a removed id');
select results_eq(
  $$ select (public.save_session_card('a1111111-0000-0000-0000-000000000001'::uuid, 5::bigint,
       public._t_card(5, 'Work talk', 'work-project'), 'Work', 'Work talk')->'card')->>'conversationMode' $$,
  $$ values ('just_talk'::text) $$, 'conversationMode survives a card save');
select is((select card->'remember'->0->>'entityId' from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'work-project', 'an entityId survives a card save');
select is((select card->>'summary' from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'Work talk', 'removed words stay in a card');

-- ── C1: forgetting an ordinary word ────────────────────────────────────────
select public.forget_entity('will');
select public.forget_entity('may');
select public.forget_entity('mark');

select is(public.redact_forgotten_text('We will see, it may rain, mark the date.'),
  'We will see, it may rain, mark the date.', 'lowercase ordinary words are left alone');
select is(public.redact_forgotten_text('I saw Will and May and Mark.'),
  'I saw someone and someone and someone.', 'the capitalized names go');
select is(public.redact_forgotten_text('Will you come?'),
  'someone you come?', 'a sentence-opening word is treated as the name (the safe direction)');

-- forgetting something only removed before upgrades it
select public.forget_entity('work');
select is(public.redact_forgotten_text('Work again, and no work.'),
  'someone again, and no work.', 'Forget after Remove starts redacting');
select is((select card->>'conversationMode' from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'just_talk', 'forget_entity leaves conversationMode');
select is((select card->'remember'->0->>'entityId' from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'work-project', 'forget_entity leaves another entity''s id');
select is(
  (select array_agg(kind order by kind) from (select distinct kind from public.entity_suppressions
    where user_id = '11111111-1111-1111-1111-111111111111') k),
  array['forgotten', 'removed'], 'both kinds are kept apart');
select is(public.remove_entity('work')->>'removedFrom', '0', 'a later Remove is harmless');
select is(public.redact_forgotten_text('Work'), 'someone', 'and leaves it forgotten');

-- ── C2: forget_entity reaches other entities and relations ─────────────────
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is((public.forget_entity_preview('maya-chen')->>'cards'), '1', 'preview counts the card');
select public.forget_entity('maya-chen');

select is((select description from public.entities where id = 'ravi'), 'Works with someone.', 'other entity: description');
select is((select metadata->>'via' from public.entities where id = 'ravi'), 'someone', 'other entity: metadata');
select is((select questions from public.entities where id = 'ravi'),
  array['How is someone?', 'Is he well?'], 'other entity: questions');
select is((select metadata->>'note' from public.relations where id = 'ravi__knows__ravi'), 'via someone', 'relation metadata');
select is((select revision from public.notebooks where id = 'b2222222-0000-0000-0000-000000000002'),
  4::bigint, 'a notebook with only text redacted still moves on');
select is((select source_revision from public.session_cards where notebook_id = 'b2222222-0000-0000-0000-000000000002'),
  4::bigint, 'its current card stays current');
reset role;
select is((select count(*) from public.entity_embeddings where entity_id = 'ravi'), 0::bigint,
  'the embedding made from the old text goes');
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

-- ── C2: the commit path ────────────────────────────────────────────────────
create temp table r as select public.commit_notebook(
  'b2222222-0000-0000-0000-000000000001'::uuid, 4::bigint, gen_random_uuid(),
  jsonb_build_object('kind', 'applyTurn',
    'entry', jsonb_build_object('text', 'I called Maya Chen.', 'entityIds', '["maya-chen","ravi"]'::jsonb),
    'entities', jsonb_build_array(
      jsonb_build_object('id', 'maya-chen', 'name', 'Maya Chen', 'type', 'person', 'mentions', 1),
      jsonb_build_object('id', 'ravi', 'name', 'Ravi', 'type', 'person', 'mentions', 1,
        'description', 'Knows Maya Chen.', 'metadata', '{"via":"Maya Chen"}'::jsonb,
        'questions', '["Did Maya Chen call?"]'::jsonb)),
    'relations', jsonb_build_array(
      jsonb_build_object('id', 'ravi__met__ravi', 'source', 'ravi', 'target', 'ravi', 'label', 'met',
        'metadata', '{"note":"with Maya Chen"}'::jsonb)),
    'followUp', '{"question":"How did the call with Maya Chen go?","reason":"","targetEntityIds":[]}'::jsonb,
    'askedQuestion', '{"question":"Was Maya Chen there?","targetEntityIds":[]}'::jsonb)) as res;

select is((select res->>'status' from r), 'committed', 'commit: the turn commits');
select is((select res->'suppressedIds' from r), '["maya-chen"]'::jsonb, 'commit: names the id it dropped');
select is((select count(*) from public.entities where id = 'maya-chen'), 0::bigint, 'commit: the person stays gone');
select is((select count(*) from public.follow_ups where notebook_id = 'b2222222-0000-0000-0000-000000000001'),
  0::bigint, 'commit: a follow-up naming them is dropped');
select is((select count(*) from public.asked_questions where notebook_id = 'b2222222-0000-0000-0000-000000000001'),
  0::bigint, 'commit: an asked question naming them is dropped');
select is((select description from public.entities where id = 'ravi' and notebook_id = 'b2222222-0000-0000-0000-000000000001'),
  'Knows someone.', 'commit: description redacted');
select is((select metadata->>'via' from public.entities where id = 'ravi' and notebook_id = 'b2222222-0000-0000-0000-000000000001'),
  'someone', 'commit: metadata redacted');
select is((select questions from public.entities where id = 'ravi' and notebook_id = 'b2222222-0000-0000-0000-000000000001'),
  array['Did someone call?'], 'commit: questions redacted');
select is((select metadata->>'note' from public.relations where id = 'ravi__met__ravi'),
  'with someone', 'commit: relation metadata redacted');
select is(public.commit_notebook(
    'b2222222-0000-0000-0000-000000000001'::uuid, 5::bigint, gen_random_uuid(),
    jsonb_build_object('kind', 'applyTurn', 'entry', jsonb_build_object('text', 'x'),
      'followUp', '{"question":"How is she?","targetEntityIds":["maya-chen"]}'::jsonb))->>'status',
  'committed', 'commit: a follow-up targeting them commits');
select is((select count(*) from public.follow_ups where notebook_id = 'b2222222-0000-0000-0000-000000000001'),
  0::bigint, 'commit: and is dropped');
reset role;
select is((select count(*) from public.notebook_commit_requests where result ? 'suppressedIds'), 0::bigint,
  'the readable id is never stored in the ledger');
set local role authenticated;

-- ── I3: names with no Latin letters ────────────────────────────────────────
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select public.forget_entity('e-1730000000000');
select public.forget_entity('иван');
select public.forget_entity('李雷');

select is(public.redact_forgotten_text('मैं प्रिया से मिला'), 'मैं someone से मिला', 'Devanagari, matched by name under an old id');
select is(public.redact_forgotten_text('Вчера Иван звонил'), 'Вчера someone звонил', 'Cyrillic');
select is(public.redact_forgotten_text('вчера иван звонил'), 'вчера иван звонил', 'Cyrillic in lowercase, the same rule as Latin');
select is(public.redact_forgotten_text('我和李雷吃饭'), '我和someone吃饭', 'Chinese inside a run with no spaces');
select is((select count(*) from public.entities where user_id = '33333333-3333-3333-3333-333333333333'),
  0::bigint, 'all three are gone');
select is(public.commit_notebook(
    'c3333333-0000-0000-0000-000000000001'::uuid,
    (select revision from public.notebooks where id = 'c3333333-0000-0000-0000-000000000001'), gen_random_uuid(),
    jsonb_build_object('kind', 'applyTurn', 'entry', jsonb_build_object('text', 'x'),
      'entities', jsonb_build_array(jsonb_build_object('id', 'иван', 'name', 'Иван', 'type', 'person', 'mentions', 1))))->'suppressedIds',
  '["иван"]'::jsonb, 'a re-mention does not recreate them');

-- ── M2 ─────────────────────────────────────────────────────────────────────
select lives_ok($$ select public.redact_forgotten_text(repeat('a', 2097152)) $$, '2 MiB is accepted');
select throws_ok($$ select public.redact_forgotten_text(repeat('a', 2097153)) $$,
  '22023', null, 'one byte over is refused');

-- ── private ────────────────────────────────────────────────────────────────
select throws_ok($$ select public._redact_text('x', '\x00'::bytea, '{}', false) $$,
  '42501', null, 'the matcher is not callable by users');
select throws_ok($$ select public._forgotten_ids('11111111-1111-1111-1111-111111111111', '{x}') $$,
  '42501', null, 'nor the forgotten-id check');

select * from finish();
rollback;
