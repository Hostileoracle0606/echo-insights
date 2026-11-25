-- pgTAP: LM-128 - get_unfinished_work only considers notebooks active in the
-- last 14 days (active = coalesce(ended_at, started_at)), and the brief's
-- "latest" notebook is the one that ENDED most recently.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(11);

insert into auth.users (id) values
  ('55555555-5555-5555-5555-555555555555'),
  ('66666666-6666-6666-6666-666666666666'),
  ('77777777-7777-7777-7777-777777777777');

-- User 5: the window boundary.
--   A started 13d23h ago, never ended            in
--   B started 14d1h ago, never ended             out
--   C started 20 days ago, ended 1 hour ago      in (the end time governs)
--   D started 20 days ago, ended 15 days ago     out
insert into public.notebooks (id, user_id, title, started_at, ended_at, revision, conversation_mode) values
  ('a5555555-0000-0000-0000-00000000000a', '55555555-5555-5555-5555-555555555555', 'WinA', now() - interval '13 days 23 hours', null, 1, 'just_talk'),
  ('a5555555-0000-0000-0000-00000000000b', '55555555-5555-5555-5555-555555555555', 'WinB', now() - interval '14 days 1 hour', null, 1, 'just_talk'),
  ('a5555555-0000-0000-0000-00000000000c', '55555555-5555-5555-5555-555555555555', 'WinC', now() - interval '20 days', now() - interval '1 hour', 1, 'just_talk'),
  ('a5555555-0000-0000-0000-00000000000d', '55555555-5555-5555-5555-555555555555', 'WinD', now() - interval '20 days', now() - interval '15 days', 1, 'just_talk');

-- User 6: started order and ended order disagree.
--   X started 5h ago, ended 1h ago   (ended most recently)
--   Y started 2h ago, ended 3h ago   (started most recently)
insert into public.notebooks (id, user_id, title, started_at, ended_at, revision, conversation_mode) values
  ('a6666666-0000-0000-0000-00000000000a', '66666666-6666-6666-6666-666666666666', 'EndX', now() - interval '5 hours', now() - interval '1 hour', 2, 'just_talk'),
  ('a6666666-0000-0000-0000-00000000000b', '66666666-6666-6666-6666-666666666666', 'EndY', now() - interval '2 hours', now() - interval '3 hours', 2, 'just_talk');

-- User 7: 60 old notebooks and one recent one: the old ones never crowd the
-- 50-card cap or set truncated.
insert into public.notebooks (id, user_id, title, started_at, revision, conversation_mode)
  select ('c7777777-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, '77777777-7777-7777-7777-777777777777',
         'Old' || g, now() - interval '30 days' - make_interval(mins => g), 1, 'just_talk'
  from generate_series(1, 60) g;
insert into public.notebooks (id, user_id, title, started_at, revision, conversation_mode) values
  ('c7777777-0000-0000-0000-ffffffffffff', '77777777-7777-7777-7777-777777777777', 'Recent', now() - interval '1 hour', 1, 'just_talk');

-- Every notebook has one entity (so it is eligible).
insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen)
  select 'ew-' || n.id, n.user_id, n.id, 'Zebra' || n.title, 'person', null, '{}', null, 1, now(), now()
  from public.notebooks n
  where n.user_id in ('55555555-5555-5555-5555-555555555555',
                      '66666666-6666-6666-6666-666666666666',
                      '77777777-7777-7777-7777-777777777777');

set local role authenticated;

-- User 5.
set local request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select is(jsonb_array_length(public.get_unfinished_work() -> 'cards'), 2,
  'cards: only the notebooks active within 14 days');
select is((select array_agg(c ->> 'notebookId' order by c ->> 'notebookId')
           from jsonb_array_elements(public.get_unfinished_work() -> 'cards') c),
  array['a5555555-0000-0000-0000-00000000000a', 'a5555555-0000-0000-0000-00000000000c'],
  'A (13d23h, never ended) and C (old start, ended 1h ago) are in');
select is((select count(*)::int from jsonb_array_elements(public.get_unfinished_work() -> 'cards') c
           where c ->> 'notebookId' in ('a5555555-0000-0000-0000-00000000000b', 'a5555555-0000-0000-0000-00000000000d')),
  0, 'B (14d1h, never ended) and D (ended 15 days ago) are out');
select is(jsonb_array_length(public.get_unfinished_work() -> 'vectors'), 4,
  'vectors are not windowed (the server sweep owns them)');
select is(public.get_unfinished_work() -> 'briefs' -> 0 ->> 'notebookId', 'a5555555-0000-0000-0000-00000000000c',
  'the brief candidate is the most recently ended notebook inside the window');

-- User 6: the brief follows the end time.
set local request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
reset role;
insert into public.session_briefs (user_id, source_notebook_id, source_revision, brief, audio, sample_rate) values
  ('66666666-6666-6666-6666-666666666666', 'a6666666-0000-0000-0000-00000000000a', 2, '{}'::jsonb, '\x00', 24000);
set local role authenticated;
select is(public.get_unfinished_work() -> 'briefs', '[]'::jsonb,
  'a brief at the revision of the most recently ENDED notebook is finished, though another notebook started later');

reset role;
update public.session_briefs set source_revision = 1;
set local role authenticated;
select is(public.get_unfinished_work() -> 'briefs' -> 0 ->> 'notebookId', 'a6666666-0000-0000-0000-00000000000a',
  'a stale brief for the most recently ended notebook is listed for it');

reset role;
update public.session_briefs
   set source_notebook_id = 'a6666666-0000-0000-0000-00000000000b', source_revision = 2;
set local role authenticated;
select is(public.get_unfinished_work() -> 'briefs' -> 0 ->> 'notebookId', 'a6666666-0000-0000-0000-00000000000a',
  'a brief for an earlier-ended notebook leaves the latest-ended one listed');

-- The live path's brief is never replaced: it is written for the notebook it
-- just ended, whose ended_at is then the latest, so nothing is listed.
reset role;
update public.notebooks set ended_at = now() where id = 'a6666666-0000-0000-0000-00000000000b';
set local role authenticated;
select is(public.get_unfinished_work() -> 'briefs', '[]'::jsonb,
  'the notebook the live path just ended (brief at its revision) is the latest: nothing to replace');

-- User 7.
set local request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
select is(jsonb_array_length(public.get_unfinished_work() -> 'cards'), 1,
  'old notebooks never reach the cards list');
select is((public.get_unfinished_work() ->> 'truncated')::boolean, true,
  'vectors (not windowed) still truncate at 50, as before');

select * from finish();
rollback;
