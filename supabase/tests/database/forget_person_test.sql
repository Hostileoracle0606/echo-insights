-- pgTAP tests for "Forget a person" (LM-49): forget_entity_preview,
-- forget_entity, hashed suppressions. Run: supabase test db
--
-- A has two notebooks that both mention Priya, and a bystander Maya; B has an
-- identical Priya. Every statement in forget_entity is SECURITY DEFINER, so B's
-- rows are checked after each step.
create extension if not exists pgtap;

begin;
select plan(54);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into public.notebooks (id, user_id, title, summary, started_at, revision) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Dinner with Priya', 'Talked about Priya''s move', now(), 5),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Work', 'A quiet day', now(), 5),
  ('a1111111-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Walk', 'Fresh air', now(), 5),
  ('b2222222-0000-0000-0000-000000000009', '22222222-2222-2222-2222-222222222222', 'B1', 'B', now(), 5);

insert into public.entities (id, user_id, notebook_id, name, type, mentions, first_seen, last_seen) values
  ('priya', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Priya', 'person', 2, now(), now()),
  ('priya', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Priya', 'person', 1, now(), now()),
  ('maya',  '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Maya',  'person', 1, now(), now()),
  ('priya', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000009', 'Priya', 'person', 1, now(), now());

insert into public.relations (id, user_id, notebook_id, source_id, target_id, label) values
  ('priya__friend_of__maya', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'priya', 'maya', 'friend_of'),
  ('priya__friend_of__maya', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000009', 'priya', 'maya', 'friend_of');
insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
  select notebook_id, id, user_id, array_fill(0.0::real, array[384])::vector, 'm', 'h'
  from public.entities where id = 'priya';
insert into public.follow_ups (user_id, notebook_id, question, target_entity_ids) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'How is she?', '{priya}'),
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000003', 'Did Priya call back?', '{}'),
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000003', 'Unrelated?', '{}'),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000009', 'How is she?', '{priya}');
insert into public.asked_questions (user_id, notebook_id, question, target_entity_ids) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Is Priya ok?', '{priya}'),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000009', 'Is Priya ok?', '{priya}');

insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'just_talk', 5,
   '{"title":"Priya and the move","summary":"You talked about PRIYA.","notes":["Priya is moving","Rent is due"],
     "remember":[{"entityId":"priya","name":"Priya","note":"Moving"},{"entityId":"maya","name":"Maya","note":"Helps"}]}'),
  ('a1111111-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'just_talk', 5,
   '{"title":"Walk","summary":"Fresh air.","notes":["Priyanka was there"],"remember":[]}'),
  ('b2222222-0000-0000-0000-000000000009', '22222222-2222-2222-2222-222222222222', 'just_talk', 5,
   '{"title":"Priya","summary":"B","notes":["Priya"],"remember":[]}');
insert into public.session_briefs (user_id, source_notebook_id, source_revision, brief, audio, sample_rate) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 5,
   '{"focus":[],"openingThread":"Priya''s move","openingLine":"Hi"}', '\x00', 24000),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000009', 5,
   '{"focus":[],"openingThread":"Priya","openingLine":"Hi"}', '\x00', 24000);

-- ── access ─────────────────────────────────────────────────────────────────
set local role anon;
select throws_ok($$ select public.forget_entity('priya') $$, '42501', null, 'anon cannot forget');
select throws_ok($$ select public.forget_entity_preview('priya') $$, '42501', null, 'anon cannot preview');

set local role authenticated;
set local request.jwt.claim.sub = '';
select throws_ok($$ select public.forget_entity('priya') $$, '42501', null, 'no signed-in user cannot forget');
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select throws_ok($$ select public._suppression_hash('11111111-1111-1111-1111-111111111111', 'priya') $$,
  '42501', null, 'the hashing helper is not callable by users');
select throws_ok($$ select count(*) from public.suppression_keys $$,
  '42501', null, 'the per-user keys are not readable by users');

-- ── preview (A) ────────────────────────────────────────────────────────────
select is(
  public.forget_entity_preview('priya'),
  '{"notebooks":2,"relations":1,"followUps":2,"askedQuestions":1,"cards":1,"briefDeleted":true,"transcriptPassages":0}'::jsonb,
  'preview: counts what would go');
select is((select count(*)::int from public.entities where id = 'priya'), 2,
  'preview: removes nothing');

-- ── forget (A) ─────────────────────────────────────────────────────────────
select is(
  public.forget_entity('priya'),
  '{"notebooks":2,"relations":1,"followUps":2,"askedQuestions":1,"cards":1,"briefDeleted":true}'::jsonb,
  'forget: returns the counts');

reset role;
select is((select count(*)::int from public.entities where id = 'priya' and user_id = '11111111-1111-1111-1111-111111111111'), 0,
  'forget: the entity is gone from every notebook');
select is((select count(*)::int from public.entities where id = 'maya' and user_id = '11111111-1111-1111-1111-111111111111'), 1,
  'forget: other entities stay');
select is((select count(*)::int from public.relations where user_id = '11111111-1111-1111-1111-111111111111'), 0,
  'forget: its relations are gone');
select is((select count(*)::int from public.entity_embeddings where entity_id = 'priya' and user_id = '11111111-1111-1111-1111-111111111111'), 0,
  'forget: its embeddings are gone');
select is((select array_agg(question) from public.follow_ups where user_id = '11111111-1111-1111-1111-111111111111'),
  array['Unrelated?'], 'forget: follow-ups about it are gone (by target and by name)');
select is((select count(*)::int from public.asked_questions where user_id = '11111111-1111-1111-1111-111111111111'), 0,
  'forget: asked questions about it are gone');
select is((select count(*)::int from public.session_briefs where user_id = '11111111-1111-1111-1111-111111111111'), 0,
  'forget: a brief that mentions it is deleted');

select is((select card->>'title' from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'someone and the move', 'card: title is redacted');
select is((select card->>'summary' from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'You talked about someone.', 'card: matching ignores case');
select is((select card->'notes'->>0 from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'someone is moving', 'card: text fields are redacted');
select is((select card->'remember' from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  '[{"entityId":"maya","name":"Maya","note":"Helps"}]'::jsonb, 'card: its "remember" item is dropped, others stay');
select is((select card->'notes'->>0 from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000003'),
  'Priyanka was there', 'card: a longer name that merely contains it is not touched');
select is(
  (select array_agg(title || ' / ' || summary order by title) from public.notebooks
    where user_id = '11111111-1111-1111-1111-111111111111' and title like '%someone%'),
  array['Dinner with someone / Talked about someone''s move'], 'notebook title and summary are redacted');
select is(
  (select array_agg(revision order by id) from public.notebooks where user_id = '11111111-1111-1111-1111-111111111111'),
  array[6::bigint, 6, 5], 'revision is bumped where the graph changed, so devices reload');

select is(
  (select source_revision from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  6::bigint, 'forget: the redacted card is marked current, so it is not regenerated');
select is(
  (select (card->>'sourceRevision')::bigint from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  6::bigint, 'forget: and the card JSON says so too');

-- ── the suppression is a keyed hash ────────────────────────────────────────
select is(
  (select entity_hash from public.entity_suppressions where user_id = '11111111-1111-1111-1111-111111111111'),
  (select encode(extensions.hmac(convert_to('priya', 'UTF8'), k.key, 'sha256'), 'hex')
     from public.suppression_keys k where k.user_id = '11111111-1111-1111-1111-111111111111'),
  'suppression: stored as the keyed hash, not the slug');
select ok(
  (select entity_hash !~* 'priya' and length(entity_hash) = 64
     from public.entity_suppressions where user_id = '11111111-1111-1111-1111-111111111111'),
  'suppression: the name is not in it');

-- ── a later session that mentions the name does not bring it back ──────────
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.commit_notebook(
  'a1111111-0000-0000-0000-000000000002'::uuid, 6::bigint, 'c0000000-0000-0000-0000-000000000001'::uuid,
  '{"kind":"applyTurn",
    "entry":{"text":"Priya called Maya.","entityIds":["priya","maya"],"relationIds":["priya__called__maya"]},
    "entities":[
      {"id":"priya","name":"Priya","type":"person","metadata":{},"mentions":1,
       "firstSeen":"2026-11-04T00:00:00Z","lastSeen":"2026-11-04T00:00:00Z"},
      {"id":"maya","name":"Maya","type":"person","metadata":{},"mentions":2,
       "firstSeen":"2026-11-04T00:00:00Z","lastSeen":"2026-11-04T00:00:00Z"}],
    "relations":[{"id":"priya__called__maya","source":"priya","target":"maya","label":"called","metadata":{},
                  "createdAt":"2026-11-04T00:00:00Z"}]}'::jsonb
) as later_turn \gset
select is(:'later_turn'::jsonb ->> 'status', 'committed', 'later turn: still commits');
select is((select count(*)::int from public.entities where id = 'priya'), 0, 'later turn: Priya is not recreated');
select is((select count(*)::int from public.entities where id = 'maya' and notebook_id = 'a1111111-0000-0000-0000-000000000002'), 1,
  'later turn: the rest of it is stored');

-- forgetting again is harmless
select is((public.forget_entity('priya') ->> 'notebooks')::int, 0, 'forget twice: nothing left, no error');

-- ── regeneration cannot bring the name back (R10) ──────────────────────────
select is(public.redact_forgotten_text('I saw Priya and Priya''s dog. PRIYA, hi!'),
  'I saw someone and someone''s dog. someone, hi!', 'redact: capitalized, possessive, punctuation');
select is(public.redact_forgotten_text('Priyanka and Maya went'), 'Priyanka and Maya went',
  'redact: a different name that starts the same is left alone');
select is(public.redact_forgotten_text(E'first\u0001Priya\u0001third'), E'first\u0001someone\u0001third',
  'redact: separators between turns survive');

-- the notebook moves on, and its card is regenerated with the name in it
reset role;
update public.notebooks set revision = 6 where id = 'a1111111-0000-0000-0000-000000000003';
set local role authenticated;
select public.save_session_card(
  'a1111111-0000-0000-0000-000000000003'::uuid, 6::bigint,
  '{"version":1,"notebookId":"a1111111-0000-0000-0000-000000000003","conversationMode":"just_talk","sourceRevision":6,
    "title":"Walk with Priya","summary":"You and Priya walked.","notes":["Priya said hi"],
    "remember":[{"entityId":"priya","name":"Priya","note":null,"isNew":true},{"entityId":"maya","name":"Maya","note":null,"isNew":false}]}'::jsonb,
  'Walk with Priya', 'You and Priya walked.', true) as regen \gset
select is((select card->>'summary' from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000003'),
  'You and someone walked.', 'save_session_card: a summary with the name is stored redacted');
select is((select card->'notes'->>0 from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000003'),
  'someone said hi', 'save_session_card: notes are redacted');
select is((select jsonb_array_length(card->'remember') from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000003'),
  1, 'save_session_card: a "remember" item for the forgotten entity is dropped');
select is((select card->>'notebookId' from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000003'),
  'a1111111-0000-0000-0000-000000000003', 'save_session_card: ids are left alone');
select is((select title from public.notebooks where id = 'a1111111-0000-0000-0000-000000000003'),
  'Walk with someone', 'save_session_card: the notebook title is redacted');
select is((select summary from public.notebooks where id = 'a1111111-0000-0000-0000-000000000003'),
  'You and someone walked.', 'save_session_card: the notebook summary is redacted');

-- briefs that name the person are not saved
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 7::bigint,
    '{"focus":[],"openingThread":"Priya''s move","openingLine":"How is it going?"}'::jsonb, 'AAAA', 24000),
  '{"status":"unchanged"}'::jsonb, 'brief: a name in openingThread is not saved');
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 7::bigint,
    '{"focus":["rent","how Priya is doing"],"openingThread":"","openingLine":"Hi there"}'::jsonb, 'AAAA', 24000),
  '{"status":"unchanged"}'::jsonb, 'brief: a name in focus is not saved');
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 7::bigint,
    '{"focus":[],"openingThread":"","openingLine":"Hey Priya, how are you?"}'::jsonb, 'AAAA', 24000),
  '{"status":"unchanged"}'::jsonb, 'brief: a name in openingLine is not saved');
select is((select count(*)::int from public.session_briefs), 0, 'brief: nothing was stored');
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 7::bigint,
    '{"focus":[],"openingThread":"rent","openingLine":"How is the week?"}'::jsonb, 'AAAA', 24000),
  '{"status":"saved"}'::jsonb, 'brief: one without the name is saved');
select is((select count(*)::int from public.session_briefs), 1, 'brief: and stored');

-- ── round 2: dates, punctuation inside names, stale cards ──────────────────
-- C forgets Priya through the RPC (a stale card must still regenerate) and has
-- three more suppressed names, added the way the RPC would.
reset role;
insert into auth.users (id) values ('33333333-3333-3333-3333-333333333333');
insert into public.notebooks (id, user_id, title, started_at, revision) values
  ('c3333333-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'C1', now(), 4),
  ('c3333333-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'C2', now(), 1);
insert into public.entities (id, user_id, notebook_id, name, type, mentions, first_seen, last_seen) values
  ('priya', '33333333-3333-3333-3333-333333333333', 'c3333333-0000-0000-0000-000000000001', 'Priya', 'person', 1, now(), now());
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('c3333333-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'just_talk', 2,
   '{"title":"Old","summary":"About Priya.","notes":[],"remember":[],"sourceRevision":2}');
insert into public.entity_suppressions (user_id, entity_hash, kind)
  select '33333333-3333-3333-3333-333333333333', public._suppression_hash('33333333-3333-3333-3333-333333333333', x), 'forgotten'
  from unnest(array['o-brien', 'st-john', 'maya-chen']) x;

set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select public.forget_entity('priya') as c_forget \gset
select is((select source_revision from public.session_cards where notebook_id = 'c3333333-0000-0000-0000-000000000001'),
  2::bigint, 'forget: a card that was already stale keeps its revision, so it regenerates');
select is((select card->>'summary' from public.session_cards where notebook_id = 'c3333333-0000-0000-0000-000000000001'),
  'About someone.', 'forget: and it is still redacted');

select public.save_session_card(
  'c3333333-0000-0000-0000-000000000002'::uuid, 1::bigint,
  '{"version":1,"notebookId":"c3333333-0000-0000-0000-000000000002","conversationMode":"just_talk","sourceRevision":1,
    "title":"T","summary":"S","weekOf":"2026-11-04","remember":[],
    "notes":["2026-11-04 dinner with Priya","O''Brien called","Met St. John today","Maya, Chen left"]}'::jsonb,
  'T', 'S', false) as c_save \gset
select is((select card->'notes'->>0 from public.session_cards where notebook_id = 'c3333333-0000-0000-0000-000000000002'),
  '2026-11-04 dinner with someone', 'a date-prefixed note naming the person is redacted');
select is((select card->'notes'->>1 from public.session_cards where notebook_id = 'c3333333-0000-0000-0000-000000000002'),
  'someone called', 'O''Brien is matched');
select is((select card->'notes'->>2 from public.session_cards where notebook_id = 'c3333333-0000-0000-0000-000000000002'),
  'Met someone today', 'St. John is matched');
select is((select card->'notes'->>3 from public.session_cards where notebook_id = 'c3333333-0000-0000-0000-000000000002'),
  'Maya, Chen left', 'a comma between two words does not form a name');
select is((select card->>'weekOf' from public.session_cards where notebook_id = 'c3333333-0000-0000-0000-000000000002'),
  '2026-11-04', 'a pure date is left alone');
reset role;

-- ── B is untouched, and cannot see A's suppressions ────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(
  (select array[(select count(*) from public.entities where id = 'priya'),
                (select count(*) from public.relations),
                (select count(*) from public.follow_ups),
                (select count(*) from public.asked_questions),
                (select count(*) from public.session_briefs),
                (select count(*) from public.entity_suppressions)]::int[]),
  array[1, 1, 1, 1, 1, 0], 'neighbour: B''s Priya, relation, questions and brief remain, and B has no suppression');
select is((select card->>'title' from public.session_cards), 'Priya', 'neighbour: B''s card is not redacted');
reset role;

select * from finish();
rollback;
