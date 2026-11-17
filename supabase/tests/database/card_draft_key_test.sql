-- pgTAP: LM-102 follow-up. A draft never claims the card key.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(18);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into public.notebooks (id, user_id, title, title_source, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 3, 'just_talk'),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 3, 'just_talk');

create function public._test_card(p_notebook uuid, p_revision bigint, p_title text)
returns jsonb language sql as $$
  select jsonb_build_object(
    'version', 1, 'notebookId', p_notebook, 'conversationMode', 'just_talk',
    'sourceRevision', p_revision, 'generatedAt', '2026-11-16T12:00:00Z',
    'title', p_title, 'summary', 'S', 'remember', '[]'::jsonb,
    'notes', jsonb_build_array('A note.'));
$$;
grant execute on function public._test_card(uuid, bigint, text) to anon, authenticated;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── 1. a draft at R is present, flagged as a draft ─────────────────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Draft'), 'Draft', 'S',
    p_draft => true)->>'status', 'saved', 'draft saved');
select is(public.get_card_status('a1111111-0000-0000-0000-000000000001', 3),
  '{"status":"present","cardRevision":3,"currentRevision":3,"draft":true}'::jsonb,
  'status: a draft at the current revision is present with draft true');
select is((select payload_hash is null and is_draft from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'), true,
  'a draft holds no key hash');

-- ── 2. draft vs draft at the same revision keeps the first ─────────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Draft 2'), 'Draft 2', 'S',
    p_draft => true)->'card'->>'title', 'Draft', 'draft over draft at R: first kept, no keyReused');

-- ── 3. a final at R replaces the draft and takes the hash ──────────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Final'), 'Final', 'S')->'card'->>'title',
  'Final', 'final at R replaces the draft at R');
select is((select card->>'title' from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'), 'Final', 'the stored card is the final');
select is((select title from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  'Final', 'the notebook is named by the final');
select is((select payload_hash ~ '^[0-9a-f]{64}$' and not is_draft from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'), true,
  'the final took the key hash');
select is(public.get_card_status('a1111111-0000-0000-0000-000000000001', 3)->>'draft', 'false',
  'status: the final is not a draft');

-- ── 4. final vs final: same hash returns stored, other hash refused ────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Final'), 'Final', 'S')->>'status',
  'saved', 'final twice, same hash: stored card returned');
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Other final'), 'Other', 'S')->>'code',
  'keyReused', 'final over a final with another hash: keyReused');

-- ── 5. a draft never replaces a final at the same revision ─────────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Late draft'), 'Late draft', 'S',
    p_draft => true)->'card'->>'title', 'Final', 'draft at R over a final at R: the stored final comes back');
select is((select card->>'title' from public.session_cards
            where notebook_id = 'a1111111-0000-0000-0000-000000000001'), 'Final',
  'the final is untouched by the late draft');

-- ── 6. a draft at an older revision never replaces a newer final ───────────
reset role;
update public.notebooks set revision = 4 where id = 'a1111111-0000-0000-0000-000000000001';
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Old draft'), 'Old draft', 'S',
    p_draft => true)->'card'->>'title', 'Final', 'an older draft never replaces the final');
select is(public.get_card_status('a1111111-0000-0000-0000-000000000001', 4)->>'status', 'absent',
  'status: the final is for the older revision, so absent now');

-- ── 7. a final at a newer revision replaces a draft or a final ─────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 4,
    public._test_card('a1111111-0000-0000-0000-000000000001', 4, 'Final 4'), 'Final 4', 'S')->'card'->>'title',
  'Final 4', 'a newer final replaces the older final');

-- ── 8. a draft over a stored draft at a newer revision replaces it ─────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000002', 3,
    public._test_card('a1111111-0000-0000-0000-000000000002', 3, 'D'), 'D', 'S', p_draft => true)->>'status',
  'saved', 'a draft on another notebook');
select is(public.get_card_status('a1111111-0000-0000-0000-000000000002', 3)->>'draft', 'true',
  'status: that draft is flagged');

select * from finish();
rollback;
