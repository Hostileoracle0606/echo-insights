-- pgTAP: draft cards written while a conversation is still going.
-- Run: supabase test db
--
-- A draft is generated from the notebook at some revision and saved a few
-- seconds later, by which time the user may have said more (the notebook's
-- revision moved on). A final card at an old revision is refused as stale,
-- as before; a draft is kept, so the card screen has something recent to
-- show the moment the user leaves. Neither ever replaces a newer card.
create extension if not exists pgtap;

begin;
select plan(9);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into public.notebooks (id, user_id, title, title_source, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Untitled', 'auto', now(), 5, 'just_talk'),
  ('b2222222-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'Untitled', 'auto', now(), 2, 'just_talk');

create function public._test_card(p_notebook uuid, p_revision bigint, p_title text)
returns jsonb language sql as $$
  select jsonb_build_object(
    'version', 1, 'notebookId', p_notebook, 'conversationMode', 'just_talk',
    'sourceRevision', p_revision, 'generatedAt', '2026-10-31T12:00:00Z',
    'title', p_title, 'summary', 'You talked about the marathon.', 'remember', '[]'::jsonb,
    'notes', jsonb_build_array('The marathon is on Sunday.'));
$$;
grant execute on function public._test_card(uuid, bigint, text) to anon, authenticated;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── 1. a final card at an old revision is still stale ──────────────────────
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Final at 3'), 'Final at 3', 'S'),
  '{"status": "stale", "currentRevision": 5}'::jsonb,
  'a final card for an older revision is refused as stale');

-- ── 2. a draft at an old revision is kept, and names the notebook ─────────
select is(
  (public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Draft at 3'), 'Draft at 3', 'S',
    p_draft => true))->>'status',
  'saved',
  'a draft for an older revision is saved');
select is(
  (select source_revision from public.session_cards
    where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  3::bigint, 'the draft is stored at the revision it was written from');
select is(
  (select title from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  'Draft at 3', 'a draft names the notebook while the conversation goes on');

-- ── 3. a later draft replaces it; an older one never does ──────────────────
select is(
  (public.save_session_card('a1111111-0000-0000-0000-000000000001', 4,
    public._test_card('a1111111-0000-0000-0000-000000000001', 4, 'Draft at 4'), 'Draft at 4', 'S',
    p_draft => true))->'card'->>'title',
  'Draft at 4', 'a newer draft replaces the older one');
select is(
  (public.save_session_card('a1111111-0000-0000-0000-000000000001', 3,
    public._test_card('a1111111-0000-0000-0000-000000000001', 3, 'Late draft at 3'), 'Late draft at 3', 'S',
    p_draft => true))->'card'->>'title',
  'Draft at 4', 'a late draft for an older revision hands back the newer card');

-- ── 4. the final card at the current revision replaces the draft ──────────
select is(
  (public.save_session_card('a1111111-0000-0000-0000-000000000001', 5,
    public._test_card('a1111111-0000-0000-0000-000000000001', 5, 'Final'), 'Final', 'S'))->'card'->>'title',
  'Final', 'the final card replaces the draft');

-- ── 5. a draft can't be ahead of the notebook, or for someone else's ──────
select throws_ok(
  $$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', 9,
       public._test_card('a1111111-0000-0000-0000-000000000001', 9, 'Future'), 'Future', 'S',
       p_draft => true) $$,
  '22023', null, 'a draft newer than the notebook is refused');
select is(
  public.save_session_card('b2222222-0000-0000-0000-000000000003', 1,
    public._test_card('b2222222-0000-0000-0000-000000000003', 1, 'Not mine'), 'Not mine', 'S',
    p_draft => true),
  '{"status": "rejected", "code": "notFound"}'::jsonb,
  'a draft for another user''s notebook is notFound');

select * from finish();
rollback;
