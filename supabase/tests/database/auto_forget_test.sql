-- pgTAP tests for auto-forget (LM-51). Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(22);

-- A keeps 30 days, B keeps forever (null), C keeps 7 days.
insert into auth.users (id) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc');

select is((select transcript_retention_days from public.profiles
            where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'), null,
          'a new profile keeps transcripts forever');

-- ── the setter ─────────────────────────────────────────────
set local role anon;
select throws_ok($$ select public.set_transcript_retention(30) $$, null, null,
                 'anon cannot set retention');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
select is(public.set_transcript_retention(30), 30, 'owner sets 30');
select throws_ok($$ select public.set_transcript_retention(15) $$, '22023', null,
                 'an unlisted value is rejected');
select throws_ok($$ select public.set_transcript_retention(0) $$, '22023', null,
                 'zero is rejected');
select throws_ok($$ select public.set_transcript_retention(-7) $$, '22023', null,
                 'a negative value is rejected');
select throws_ok($$ update public.profiles set transcript_retention_days = 3
                    where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' $$,
                 '42501', null, 'the column cannot be written directly');
select lives_ok($$ update public.profiles set display_name = 'A'
                   where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' $$,
                'display_name is still writable');
select is((select transcript_retention_days from public.profiles), 30,
          'the owner reads their setting through the profile');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
select public.set_transcript_retention(7);
select public.set_transcript_retention(90);
select public.set_transcript_retention(null);
select public.set_transcript_retention(7);
reset role;

select is((select transcript_retention_days from public.profiles
            where user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'), null,
          'setting your own retention leaves other users alone');
select is((select transcript_retention_days from public.profiles
            where user_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'), 7,
          'C is set to 7 (null is accepted along the way)');

-- ── the sweep ──────────────────────────────────────────────
insert into public.notebooks (id, user_id, title, started_at) values
  ('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', now()),
  ('b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B', now()),
  ('c1c1c1c1-c1c1-c1c1-c1c1-c1c1c1c1c1c1', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'C', now());

-- A (30 days): one just older, one just newer. B (forever): very old.
-- C (7 days): just older than 7 but newer than 30, so only C's own setting
-- explains the delete.
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at, created_at) values
  ('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', 'old',  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'user', 'x', now(), now() - interval '30 days 1 minute'),
  ('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', 'new',  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'user', 'x', now(), now() - interval '29 days 23 hours'),
  ('b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1', 'ancient', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'user', 'x', now(), now() - interval '900 days'),
  ('c1c1c1c1-c1c1-c1c1-c1c1-c1c1c1c1c1c1', 'old',  'cccccccc-cccc-cccc-cccc-cccccccccccc', 'user', 'x', now(), now() - interval '8 days'),
  ('c1c1c1c1-c1c1-c1c1-c1c1-c1c1c1c1c1c1', 'new',  'cccccccc-cccc-cccc-cccc-cccccccccccc', 'user', 'x', now(), now() - interval '6 days 23 hours');
insert into public.journal_entries (user_id, notebook_id, text, created_at) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', 'old',  now() - interval '30 days 1 minute'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', 'new',  now() - interval '29 days 23 hours'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1', 'ancient', now() - interval '900 days');

-- What stays: cards, entities, relations, follow-ups, briefs.
insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen)
  select 'maya', user_id, id, 'Maya', 'person', now() - interval '900 days', now() from public.notebooks;
insert into public.relations (id, user_id, notebook_id, source_id, target_id, label)
  select 'r1', user_id, id, 'maya', 'maya', 'knows' from public.notebooks;
insert into public.follow_ups (user_id, notebook_id, question)
  select user_id, id, 'q?' from public.notebooks;
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card)
  select id, user_id, 'just_talk', 1, '{}'::jsonb from public.notebooks;
insert into public.session_briefs (user_id, source_notebook_id, source_revision, brief, audio, sample_rate)
  select user_id, id, 1, '{}'::jsonb, '\x00', 24000 from public.notebooks;
update public.session_cards set created_at = now() - interval '900 days';

select is((public.forget_old_transcripts(1)), jsonb_build_object('turns', 2, 'entries', 1),
          'the sweep reports what it deleted (batch of 1 loops to the end)');

select is((select array_agg(turn_id order by turn_id) from public.conversation_turns
            where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'), array['new'],
          '30 days: the turn just over is deleted, the one just under stays');
select is((select array_agg(text order by text) from public.journal_entries
            where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'), array['new'],
          '30 days: same for journal entries');
select is((select array_agg(turn_id order by turn_id) from public.conversation_turns
            where user_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'), array['new'],
          '7 days: each user is measured against their own setting');
select is((select count(*) from public.conversation_turns
            where user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'), 1::bigint,
          'null retention keeps an ancient turn');
select is((select count(*) from public.journal_entries
            where user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'), 1::bigint,
          'null retention keeps an ancient entry');

select is((select count(*) from public.entities), 3::bigint, 'entities survive');
select is((select count(*) from public.relations) + (select count(*) from public.follow_ups)
          + (select count(*) from public.session_cards) + (select count(*) from public.session_briefs),
          12::bigint, 'relations, follow-ups, cards and briefs survive');

select is(public.forget_old_transcripts(), jsonb_build_object('turns', 0, 'entries', 0),
          'a second sweep finds nothing');

-- ── not callable through the API ───────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
select throws_ok($$ select public.forget_old_transcripts() $$, '42501', null,
                 'a signed-in user cannot run the sweep');
reset role;

-- ── the schedule ───────────────────────────────────────────
select is((select count(*) from cron.job
            where jobname = 'forget-old-transcripts'
              and schedule = '15 3 * * *'
              and command = 'select public.forget_old_transcripts()'), 1::bigint,
          'the daily job is scheduled, once');

select * from finish();
rollback;
