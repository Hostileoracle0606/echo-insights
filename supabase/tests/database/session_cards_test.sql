-- pgTAP tests for session cards (LM-15): session_cards RLS and
-- save_session_card. Run: supabase test db
--
-- save_session_card is SECURITY DEFINER, so every check runs against a second
-- user too: one missing user filter would let B write A's card or title.
create extension if not exists pgtap;

begin;
select plan(32);

-- ── fixtures (default role, so RLS doesn't apply while seeding) ────────────
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

-- A owns N1 ('auto' title), N2 (named by the user) and N5 (a debrief);
-- B owns N3.
insert into public.notebooks (id, user_id, title, title_source, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 3, 'just_talk'),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'My own name', 'user', now(), 5, 'just_talk'),
  ('a1111111-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 1, 'weekly_debrief'),
  ('b2222222-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'Untitled', 'auto', now(), 2, 'just_talk');

-- A minimal just_talk card for a notebook at a revision.
-- Lives in public only inside this rolled-back transaction.
create function public._test_card(p_notebook uuid, p_revision bigint, p_title text)
returns jsonb language sql as $$
  select jsonb_build_object(
    'version', 1, 'notebookId', p_notebook, 'conversationMode', 'just_talk',
    'sourceRevision', p_revision, 'generatedAt', '2026-10-24T12:00:00Z',
    'title', p_title, 'summary', 'You talked about Maya.', 'remember', '[]'::jsonb,
    'notes', jsonb_build_array('Maya is moving.'));
$$;
grant execute on function public._test_card(uuid, bigint, text) to anon, authenticated;

-- ── 1. anon can neither call the RPC nor read cards ────────────────────────
set local role anon;
select throws_ok(
  $$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
       public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'T'), 'T', 'S') $$,
  '42501', null, 'anon cannot call save_session_card');
select throws_ok($$ select * from public.session_cards $$, '42501', null,
  'anon cannot read session_cards');
reset role;

-- ── 2. only the RPC writes ─────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select throws_ok(
  $$ insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card)
     values ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
             'just_talk', 3, '{}'::jsonb) $$,
  '42501', null, 'an owner cannot insert a card directly');

-- ── 3. a stale revision is refused and writes nothing ──────────────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 2,
    public._test_card('a1111111-0000-0000-0000-000000000001', 2, 'Old'), 'Old', 'Old summary'),
  '{"status": "stale", "currentRevision": 3}'::jsonb,
  'stale: reports the current revision');
select is((select count(*)::int from public.session_cards), 0, 'stale: no card written');
select is((select title from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  'Untitled', 'stale: title untouched');

-- ── 4. the current revision saves, and an 'auto' title is replaced ─────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Maya''s move'),
    '  Maya''s move  ', 'You talked about Maya.'),
  jsonb_build_object('status', 'saved',
    'card', public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Maya''s move')),
  'save: returns the stored card');
select results_eq(
  $$ select user_id, conversation_mode, source_revision from public.session_cards
     where notebook_id = 'a1111111-0000-0000-0000-000000000001' $$,
  $$ values ('11111111-1111-1111-1111-111111111111'::uuid, 'just_talk'::text, 3::bigint) $$,
  'save: the row belongs to the caller at the source revision');
select results_eq(
  $$ select title, title_source, summary, revision from public.notebooks
     where id = 'a1111111-0000-0000-0000-000000000001' $$,
  $$ values ('Maya''s move'::text, 'ai'::text, 'You talked about Maya.'::text, 3::bigint) $$,
  'save: an auto title becomes the trimmed AI title; summary set; revision not bumped');

-- ── 5. the same revision twice keeps the first card ────────────────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Second try'),
    'Second try', 'Another summary.')->'card'->>'title',
  'Maya''s move',
  'duplicate: hands back the card already saved for this revision');
select is((select title from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  'Maya''s move', 'duplicate: title untouched');

-- ── 6. a newer revision replaces the card, and an 'ai' title too ───────────
reset role;
update public.notebooks set revision = 4 where id = 'a1111111-0000-0000-0000-000000000001';
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 4,
    public._test_card('a1111111-0000-0000-0000-000000000001', 4, 'Maya and the demo'),
    'Maya and the demo', 'You talked about Maya and the demo.')->>'status',
  'saved', 'newer: saves');
select results_eq(
  $$ select sc.source_revision, sc.card->>'title', nb.title, nb.title_source
     from public.session_cards sc join public.notebooks nb on nb.id = sc.notebook_id
     where sc.notebook_id = 'a1111111-0000-0000-0000-000000000001' $$,
  $$ values (4::bigint, 'Maya and the demo'::text, 'Maya and the demo'::text, 'ai'::text) $$,
  'newer: replaces the card and the AI title');

-- ── 7. a user-set title is kept ────────────────────────────────────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000002', 5,
    public._test_card('a1111111-0000-0000-0000-000000000002', 5, 'AI title'),
    'AI title', 'You talked about work.')->>'status',
  'saved', 'user title: the card still saves');
select results_eq(
  $$ select title, title_source, summary from public.notebooks
     where id = 'a1111111-0000-0000-0000-000000000002' $$,
  $$ values ('My own name'::text, 'user'::text, 'You talked about work.'::text) $$,
  'user title: kept; summary set');

-- ── 8. long or empty titles and summaries ──────────────────────────────────
reset role;
update public.notebooks set revision = 6 where id = 'a1111111-0000-0000-0000-000000000002';
update public.notebooks set title_source = 'auto' where id = 'a1111111-0000-0000-0000-000000000002';
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(public.save_session_card('a1111111-0000-0000-0000-000000000002', 6,
  public._test_card('a1111111-0000-0000-0000-000000000002', 6, 'x'), repeat('t', 90), repeat('s', 400))->>'status',
  'saved', 'limits: an over-long title and summary still save');
select results_eq(
  $$ select char_length(title), char_length(summary) from public.notebooks
     where id = 'a1111111-0000-0000-0000-000000000002' $$,
  $$ values (60, 280) $$,
  'limits: title clamped to 60, summary to 280');
reset role;
update public.notebooks set revision = 7 where id = 'a1111111-0000-0000-0000-000000000002';
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(public.save_session_card('a1111111-0000-0000-0000-000000000002', 7,
  public._test_card('a1111111-0000-0000-0000-000000000002', 7, 'x'), '   ', null)->>'status',
  'saved', 'limits: a blank title and summary still save');
select results_eq(
  $$ select title, char_length(summary) from public.notebooks
     where id = 'a1111111-0000-0000-0000-000000000002' $$,
  $$ values (repeat('t', 60), 280) $$,
  'limits: a blank title or summary leaves the old one');

-- ── 9. the card must describe this notebook at this revision ───────────────
select throws_ok(
  $$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', 4,
       public._test_card('a1111111-0000-0000-0000-000000000002', 4, 'T'), 'T', 'S') $$,
  '22023', null, 'a card for another notebook is refused');
select throws_ok(
  $$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', 4,
       public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'T'), 'T', 'S') $$,
  '22023', null, 'a card from another revision is refused');
select throws_ok(
  $$ select public.save_session_card('a1111111-0000-0000-0000-000000000005', 1,
       public._test_card('a1111111-0000-0000-0000-000000000005', 1, 'T'), 'T', 'S') $$,
  '22023', null, 'a card for another conversation mode is refused');

-- ── 10. the owner reads; B neither reads nor writes A's ────────────────────
select is((select count(*)::int from public.session_cards), 2, 'owner reads both of A''s cards');

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is((select count(*)::int from public.session_cards), 0, 'B cannot read A''s cards');
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 4,
    public._test_card('a1111111-0000-0000-0000-000000000001', 4, 'Hijack'), 'Hijack', 'Hijack'),
  '{"status": "rejected", "code": "notFound"}'::jsonb,
  'B cannot save a card on A''s notebook');
select is(
  public.save_session_card('b2222222-0000-0000-0000-000000000003', 2,
    public._test_card('b2222222-0000-0000-0000-000000000003', 2, 'B''s chat'), 'B''s chat', 'B summary')->>'status',
  'saved', 'B saves on B''s own notebook');
select is((select count(*)::int from public.session_cards), 1, 'B reads only B''s card');
select throws_ok(
  $$ update public.session_cards set card = '{}'::jsonb $$,
  '42501', null, 'B cannot update cards directly');
select throws_ok(
  $$ delete from public.session_cards $$,
  '42501', null, 'B cannot delete cards directly');

reset role;
select results_eq(
  $$ select sc.card->>'title', nb.title from public.session_cards sc
     join public.notebooks nb on nb.id = sc.notebook_id
     where sc.notebook_id = 'a1111111-0000-0000-0000-000000000001' $$,
  $$ values ('Maya and the demo'::text, 'Maya and the demo'::text) $$,
  'A''s card and title survived B''s attempts');

-- ── 11. no session at all ──────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = '';
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 4,
    public._test_card('a1111111-0000-0000-0000-000000000001', 4, 'T'), 'T', 'S'),
  '{"status": "rejected", "code": "notFound"}'::jsonb,
  'no auth.uid(): rejected');
reset role;

-- ── 12. deleting the notebook deletes its card ─────────────────────────────
delete from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001';
select is((select count(*)::int from public.session_cards
           where notebook_id = 'a1111111-0000-0000-0000-000000000001'), 0,
  'the card goes with its notebook');

select * from finish();
rollback;
