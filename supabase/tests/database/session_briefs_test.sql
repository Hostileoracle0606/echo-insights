-- pgTAP tests for session briefs (LM-37): session_briefs RLS, save_session_brief,
-- get_session_brief and mark_session_brief_played. Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(35);

-- ── fixtures (default role, so RLS doesn't apply while seeding) ────────────
-- A and B save briefs. C is fresh. D has only an entity-bearing notebook,
-- E only a user turn, F only a session card.
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333'),
  ('44444444-4444-4444-4444-444444444444'),
  ('55555555-5555-5555-5555-555555555555'),
  ('66666666-6666-6666-6666-666666666666');

insert into public.notebooks (id, user_id, title, started_at, revision, entity_count) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'A1', now(), 3, 0),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'A2', now(), 1, 0),
  ('b2222222-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'B1', now(), 1, 0),
  ('d4444444-0000-0000-0000-000000000004', '44444444-4444-4444-4444-444444444444', 'D1', now(), 1, 2),
  ('e5555555-0000-0000-0000-000000000005', '55555555-5555-5555-5555-555555555555', 'E1', now(), 1, 0),
  ('f6666666-0000-0000-0000-000000000006', '66666666-6666-6666-6666-666666666666', 'F1', now(), 1, 0);

insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at) values
  ('e5555555-0000-0000-0000-000000000005', 't1', '55555555-5555-5555-5555-555555555555', 'user', 'hello', now());
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('f6666666-0000-0000-0000-000000000006', '66666666-6666-6666-6666-666666666666', 'just_talk', 1, '{}'::jsonb);

-- ── 1. anon is denied on the table and all three functions ─────────────────
set local role anon;
select throws_ok($$ select * from public.session_briefs $$, '42501', null,
  'anon cannot read session_briefs');
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 3,
       '{"focus":[],"openingThread":"t","openingLine":"Hi"}'::jsonb, 'AAAA', 24000) $$,
  '42501', null, 'anon cannot call save_session_brief');
select throws_ok($$ select public.get_session_brief() $$, '42501', null,
  'anon cannot call get_session_brief');
select throws_ok($$ select public.mark_session_brief_played(now()) $$, '42501', null,
  'anon cannot call mark_session_brief_played');
reset role;

-- ── 2. A saves a brief ─────────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000001', 3,
    '{"focus":["Maya"],"openingThread":"the move","openingLine":"How did the move go?"}'::jsonb,
    encode(decode(repeat('0102030405060708', 40), 'hex'), 'base64'), 24000),
  '{"status": "saved"}'::jsonb, 'save: returns saved');

select is(public.get_session_brief()->'brief'->>'openingLine', 'How did the move go?',
  'get: returns the openingLine');
select is((public.get_session_brief()->'brief'->>'sampleRate')::int, 24000, 'get: sampleRate');
select is(public.get_session_brief()->'brief'->'focus', '["Maya"]'::jsonb, 'get: focus');
select is(public.get_session_brief()->'brief'->>'sourceNotebookId',
  'a1111111-0000-0000-0000-000000000001', 'get: sourceNotebookId');
select ok(length(public.get_session_brief()->'brief'->>'audioBase64') > 0
  and public.get_session_brief()->'brief'->>'audioBase64' !~ E'\n',
  'get: audioBase64 is non-empty with no newlines');
select is(
  length(decode(public.get_session_brief()->'brief'->>'audioBase64', 'base64')), 320,
  'get: audio round-trips');
select ok(public.get_session_brief()->'brief'->>'playedAt' is null
  and public.get_session_brief()->'brief' ? 'playedAt', 'get: playedAt is null before play');

-- ── 3. direct writes are refused ───────────────────────────────────────────
select throws_ok(
  $$ insert into public.session_briefs (user_id, source_revision, brief, audio, sample_rate)
     values ('11111111-1111-1111-1111-111111111111', 1, '{}'::jsonb, '\x00', 24000) $$,
  '42501', null, 'an owner cannot insert directly');
select throws_ok($$ update public.session_briefs set sample_rate = 1 $$,
  '42501', null, 'an owner cannot update directly');
select throws_ok($$ delete from public.session_briefs $$,
  '42501', null, 'an owner cannot delete directly');

-- ── 4. same notebook and revision twice is unchanged ───────────────────────
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000001', 3,
    '{"focus":[],"openingThread":"x","openingLine":"Different line"}'::jsonb, 'AQID', 24000),
  '{"status": "unchanged"}'::jsonb, 'same revision: unchanged');
select is(public.get_session_brief()->'brief'->>'openingLine', 'How did the move go?',
  'same revision: the stored brief is kept');

-- ── 5. mark played: exact created_at only ──────────────────────────────────
select lives_ok(
  $$ select public.mark_session_brief_played(
       (public.get_session_brief()->'brief'->>'createdAt')::timestamptz - interval '1 microsecond') $$,
  'mark with another timestamp runs');
select ok(public.get_session_brief()->'brief'->>'playedAt' is null,
  'mark with another timestamp changes nothing');
select lives_ok(
  $$ select public.mark_session_brief_played(
       (public.get_session_brief()->'brief'->>'createdAt')::timestamptz) $$,
  'mark with the row''s createdAt runs');
select ok(public.get_session_brief()->'brief'->>'playedAt' is not null,
  'mark with the row''s createdAt sets playedAt');

-- ── 6. a newer save replaces the row and clears played_at ──────────────────
reset role;
update public.notebooks set revision = 4 where id = 'a1111111-0000-0000-0000-000000000001';
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000001', 4,
    '{"focus":[],"openingThread":"y","openingLine":"Newer line"}'::jsonb, 'AQID', 24000),
  '{"status": "saved"}'::jsonb, 'newer: saved');
select is(public.get_session_brief()->'brief'->>'openingLine', 'Newer line', 'newer: replaces the row');
select ok(public.get_session_brief()->'brief'->>'playedAt' is null, 'newer: clears playedAt');

-- ── 7. validation ──────────────────────────────────────────────────────────
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 5,
       '{"focus":[],"openingThread":"y","openingLine":""}'::jsonb, 'AQID', 24000) $$,
  '22023', null, 'empty openingLine is refused');
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 5,
       jsonb_build_object('focus', '[]'::jsonb, 'openingThread', 'y', 'openingLine', repeat('x', 161)),
       'AQID', 24000) $$,
  '22023', null, 'over-long openingLine is refused');
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 5,
       '{"focus":[],"openingThread":"y","openingLine":"Hi"}'::jsonb, '', 24000) $$,
  '22023', null, 'empty audio is refused');

-- ── 8. B cannot see or use A's data ────────────────────────────────────────
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(public.get_session_brief()->'brief', 'null'::jsonb, 'B sees brief: null');
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000001', 9,
    '{"focus":[],"openingThread":"y","openingLine":"Hijack"}'::jsonb, 'AQID', 24000),
  '{"status": "rejected", "code": "notFound"}'::jsonb, 'B cannot save against A''s notebook');
select is((select count(*)::int from public.session_briefs), 0, 'B cannot read A''s row');

-- ── 9. returning ───────────────────────────────────────────────────────────
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select is((public.get_session_brief()->>'returning')::boolean, false, 'fresh account is not returning');
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select is((public.get_session_brief()->>'returning')::boolean, true, 'entities-only account is returning');
set local request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select is((public.get_session_brief()->>'returning')::boolean, true, 'account with a user turn is returning');
set local request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
select is((public.get_session_brief()->>'returning')::boolean, true, 'account with a card is returning');

-- ── 10. deleting the user removes the brief ────────────────────────────────
reset role;
delete from auth.users where id = '11111111-1111-1111-1111-111111111111';
select is((select count(*)::int from public.session_briefs), 0, 'the brief goes with its user');

select * from finish();
rollback;
