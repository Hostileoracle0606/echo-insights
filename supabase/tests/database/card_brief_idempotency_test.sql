-- pgTAP: LM-102 card and brief saves are keyed and safe to repeat, and the
-- phone can ask a definite question ("is it there?") instead of guessing.
-- Run: supabase test db
--
-- Card key: (notebook, source revision). Brief key: (user, notebook, source
-- revision). Each stores a hash of the payload, never the payload again.
create extension if not exists pgtap;

begin;
select plan(32);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into public.notebooks (id, user_id, title, title_source, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 3, 'just_talk'),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 1, 'just_talk'),
  ('b2222222-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'Untitled', 'auto', now(), 2, 'just_talk');

create function public._test_card(p_notebook uuid, p_revision bigint, p_title text)
returns jsonb language sql as $$
  select jsonb_build_object(
    'version', 1, 'notebookId', p_notebook, 'conversationMode', 'just_talk',
    'sourceRevision', p_revision, 'generatedAt', '2026-11-16T12:00:00Z',
    'title', p_title, 'summary', 'You talked about Maya.', 'remember', '[]'::jsonb,
    'notes', jsonb_build_array('Maya is moving.'));
$$;
grant execute on function public._test_card(uuid, bigint, text) to anon, authenticated;

-- ── 1. anon cannot call the status reads ───────────────────────────────────
set local role anon;
select throws_ok(
  $$ select public.get_card_status('a1111111-0000-0000-0000-000000000001', 3) $$,
  '42501', null, 'anon cannot call get_card_status');
select throws_ok(
  $$ select public.get_brief_status('a1111111-0000-0000-0000-000000000001', 3) $$,
  '42501', null, 'anon cannot call get_brief_status');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── 2. card status: absent, then present ───────────────────────────────────
select is(public.get_card_status('a1111111-0000-0000-0000-000000000001', 3),
  '{"status":"absent","cardRevision":null,"currentRevision":3,"draft":false}'::jsonb,
  'card status: absent before any save');

select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'First'), 'First', 'S')->>'status',
  'saved', 'card: first save');

select is(public.get_card_status('a1111111-0000-0000-0000-000000000001', 3),
  '{"status":"present","cardRevision":3,"currentRevision":3,"draft":false}'::jsonb,
  'card status: present after the save');

-- ── 3. card saved twice with the same payload: one card, same answer ───────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'First'), 'First', 'S'),
  jsonb_build_object('status', 'saved',
    'card', public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'First')),
  'card twice, same payload: the stored card comes back as saved');
select is((select count(*)::int from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'), 1,
  'card twice: still one row');

-- ── 4. same revision, changed payload: refused, nothing written ────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Changed'), 'Changed', 'S'),
  '{"status":"rejected","code":"keyReused"}'::jsonb,
  'card, same revision, different payload: keyReused');
select is((select card->>'title' from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'), 'First',
  'keyReused: the stored card is untouched');
select is((select title from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  'First', 'keyReused: the notebook title is untouched');

-- the stored hash is a hash, not text
select ok((select payload_hash ~ '^[0-9a-f]{64}$' from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'card: payload_hash is a sha256 hex digest');

-- ── 5. a row from before the ledger (null hash) adopts the first match ─────
reset role;
update public.session_cards set payload_hash = null
  where notebook_id = 'a1111111-0000-0000-0000-000000000001';
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Whatever'), 'Whatever', 'S')->>'status',
  'saved', 'old card row (no hash): adopted, not refused');
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Whatever'), 'Whatever', 'S')->>'status',
  'saved', 'old card row: the adopted hash now matches the same payload');
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Third'), 'Third', 'S')->>'code',
  'keyReused', 'old card row: after adoption a different payload is refused');

-- ── 6. stale and notFound statuses (card) ──────────────────────────────────
select is(public.get_card_status('a1111111-0000-0000-0000-000000000001', 2),
  '{"status":"stale","cardRevision":3,"currentRevision":3,"draft":false}'::jsonb,
  'card status: stale when asked about a revision that is not current');
select is(public.get_card_status('a1111111-0000-0000-0000-000000000002', 1),
  '{"status":"absent","cardRevision":null,"currentRevision":1,"draft":false}'::jsonb,
  'card status: absent for a notebook with no card');
select is(public.get_card_status('b2222222-0000-0000-0000-000000000003', 2)->>'status',
  'notFound', 'card status: notFound for someone else''s notebook');
select is(public.get_card_status('00000000-0000-0000-0000-00000000dead', 1)->>'status',
  'notFound', 'card status: notFound for a notebook that does not exist');
select ok(not (public.get_card_status('a1111111-0000-0000-0000-000000000001', 3) ? 'card'),
  'card status: never returns card text');

-- ── 7. brief: first save, twice, changed payload ───────────────────────────
select is(public.get_brief_status('a1111111-0000-0000-0000-000000000001', 3)->>'status',
  'absent', 'brief status: absent before any save');

select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000001', 3,
    '{"focus":["Maya"],"openingThread":"the move","openingLine":"How did the move go?"}'::jsonb,
    'AQID', 24000),
  '{"status":"saved"}'::jsonb, 'brief: first save');

select is(public.get_brief_status('a1111111-0000-0000-0000-000000000001', 3)->>'status',
  'present', 'brief status: present after the save');
select is((public.get_brief_status('a1111111-0000-0000-0000-000000000001', 3)->>'currentRevision')::int,
  3, 'brief status: reports the current revision');

select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000001', 3,
    '{"focus":["Maya"],"openingThread":"the move","openingLine":"How did the move go?"}'::jsonb,
    'AQID', 24000),
  '{"status":"unchanged"}'::jsonb, 'brief twice, same payload: unchanged');

select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000001', 3,
    '{"focus":[],"openingThread":"x","openingLine":"A different line"}'::jsonb, 'AQID', 24000),
  '{"status":"rejected","code":"keyReused"}'::jsonb,
  'brief, same key, different payload: keyReused');
select is(public.get_session_brief()->'brief'->>'openingLine', 'How did the move go?',
  'keyReused: the stored brief is untouched');
select ok((select payload_hash ~ '^[0-9a-f]{64}$' from public.session_briefs
            where user_id = '11111111-1111-1111-1111-111111111111'),
  'brief: payload_hash is a sha256 hex digest');

-- ── 8. old brief row (null hash) adopts ────────────────────────────────────
reset role;
update public.session_briefs set payload_hash = null
  where user_id = '11111111-1111-1111-1111-111111111111';
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000001', 3,
    '{"focus":[],"openingThread":"x","openingLine":"Whatever"}'::jsonb, 'AQID', 24000)->>'status',
  'unchanged', 'old brief row (no hash): adopted, answered unchanged');
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000001', 3,
    '{"focus":[],"openingThread":"x","openingLine":"Other"}'::jsonb, 'AQID', 24000)->>'code',
  'keyReused', 'old brief row: after adoption a different payload is refused');

-- ── 9. brief statuses: stale, absent for another notebook, notFound ────────
select is(public.get_brief_status('a1111111-0000-0000-0000-000000000001', 2)->>'status',
  'stale', 'brief status: stale when asked about a revision that is not current');
select is(public.get_brief_status('a1111111-0000-0000-0000-000000000002', 1)->>'status',
  'absent', 'brief status: absent for a notebook the brief is not from');
select is(public.get_brief_status('b2222222-0000-0000-0000-000000000003', 2)->>'status',
  'notFound', 'brief status: notFound for someone else''s notebook');

select * from finish();
rollback;
