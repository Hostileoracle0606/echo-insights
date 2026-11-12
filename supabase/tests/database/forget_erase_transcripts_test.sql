-- pgTAP: Forget with "also erase their name from my saved transcripts":
-- forget_entity(p_entity_id, p_erase_transcripts) rewrites the caller's
-- conversation_turns.text and journal_entries.text with the forget matcher,
-- and LM-63's trigger keeps context_text consistent with the new text.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(26);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into public.notebooks (id, user_id, title, summary, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N1', 'S', now(), 3, 'just_talk'),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'N2', 'S', now(), 5, 'just_talk'),
  ('b2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'N', 'S', now(), 3, 'just_talk');

insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen) values
  ('priya-raman', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Priya Raman', 'person', null, '{}', null, 1, now(), now()),
  ('priya-nair', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Priya Nair', 'person', null, '{}', null, 1, now(), now()),
  ('work', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'work', 'topic', null, '{}', null, 1, now(), now()),
  ('sam', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Sam', 'person', null, '{}', null, 1, now(), now()),
  ('priya-raman', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Priya Raman', 'person', null, '{}', null, 1, now(), now());

insert into public.journal_entries (user_id, notebook_id, text, created_at, entity_ids) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'Priya Raman called. Work was fine.', now(), array['priya-raman', 'work']),
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002',
   'Lunch with Priya Nair.', now(), array['priya-nair']),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001',
   'Priya Raman visited.', now(), array['priya-raman']);

insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at)
  select 'a1111111-0000-0000-0000-000000000002', 'bulk-' || g, '11111111-1111-1111-1111-111111111111',
         'user', 'Turn ' || g || ': Priya Raman said hi.', now() - make_interval(secs => 1000 - g)
  from generate_series(1, 600) g;
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at) values
  ('a1111111-0000-0000-0000-000000000001', 't1', '11111111-1111-1111-1111-111111111111', 'user', 'Priya Raman called. Work was fine.', now()),
  ('a1111111-0000-0000-0000-000000000001', 't2', '11111111-1111-1111-1111-111111111111', 'assistant', 'How is Priya Raman?', now()),
  ('a1111111-0000-0000-0000-000000000001', 't3', '11111111-1111-1111-1111-111111111111', 'user', 'Priya Nair is fine.', now()),
  ('a1111111-0000-0000-0000-000000000001', 't4', '11111111-1111-1111-1111-111111111111', 'user', 'Sam and Priya Raman talked.', now()),
  ('b2222222-0000-0000-0000-000000000001', 'u1', '22222222-2222-2222-2222-222222222222', 'user', 'Priya Raman visited.', now());

insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'just_talk', 5,
   '{"title":"T","summary":"Lunch.","notes":[],"remember":[],"sourceRevision":5}');

set local role authenticated;

-- Owner-only: no anon, and no way to name another user.
set local role anon;
select throws_ok($$select public.forget_entity('priya-raman', true)$$, '42501', null, 'anon cannot call it');
set local role authenticated;
select throws_ok($$select public.forget_entity('priya-raman', true)$$, '42501', null, 'no caller, no rewrite');

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.remove_entity('work');
-- Sam is forgotten first, without erasing: the erase must leave his name in
-- text while context_text keeps redacting it.
select public.forget_entity('sam');

select is((public.forget_entity_preview('priya-raman') ->> 'transcriptPassages')::int, 604,
  'preview: counts every turn and entry that names her (603 turns, 1 entry)');
select is(public.forget_entity('priya-raman', false) ? 'transcriptPassages', false,
  'erase off: an ordinary forget');
select is((select count(*)::int from public.conversation_turns where text like '%Priya Raman%'), 603,
  'erase off: turns keep the words');
select is((select context_text from public.conversation_turns where turn_id = 'bulk-600'), 'Turn 600: someone said hi.',
  'erase off: Lumen reads them redacted (LM-63)');
reset role;
-- Run the erase as part of a fresh forget of the same person.
set local role authenticated;
select is((public.forget_entity('priya-raman', true) ->> 'transcriptPassages')::int, 604,
  'erase on: reports how many passages changed');

reset role;
select is((select count(*)::int from public.conversation_turns
           where user_id = '11111111-1111-1111-1111-111111111111' and text like '%Priya Raman%'), 0,
  'turns: no turn of the caller''s names her, across notebooks and batches');
select is((select text from public.conversation_turns where turn_id = 'bulk-600'), 'Turn 600: someone said hi.',
  'turns: the last batch is rewritten');
select is((select text from public.conversation_turns where turn_id = 't2'), 'How is someone?', 'turns: Lumen''s turns too');
select is((select context_text from public.conversation_turns where turn_id = 'bulk-600'), null,
  'context_text: null once text names no forgotten person');
select is((select text from public.conversation_turns where turn_id = 't4'), 'Sam and someone talked.',
  'turns: only her name is erased, not another forgotten person''s');
select is((select context_text from public.conversation_turns where turn_id = 't4'), 'someone and someone talked.',
  'context_text: recomputed from the new text, still redacting Sam');
select is((select count(*)::int from public.conversation_turns
           where user_id = '11111111-1111-1111-1111-111111111111'
             and context_text is distinct from public._context_text(user_id, text)), 0,
  'context_text matches text on every turn of the caller''s');
select is((select count(*)::int from public.journal_entries
           where user_id = '11111111-1111-1111-1111-111111111111'
             and context_text is distinct from public._context_text(user_id, text)), 0,
  'context_text matches text on every entry of the caller''s');
select is((select text from public.conversation_turns where turn_id = 't3'), 'Priya Nair is fine.', 'turns: Priya Nair is untouched');
select is((select text from public.journal_entries where 'priya-nair' = any(entity_ids)), 'Lunch with Priya Nair.',
  'entries: Priya Nair is untouched');
select is((select text from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'someone called. Work was fine.', 'entries: her name, and the removed (not forgotten) word "Work" stays');
select is((select text from public.conversation_turns where turn_id = 't1'), 'someone called. Work was fine.',
  'turns: the removed word "Work" stays');
select is((select text from public.conversation_turns where turn_id = 'u1'), 'Priya Raman visited.',
  'other users: their turns are untouched');
select is((select text from public.journal_entries where user_id = '22222222-2222-2222-2222-222222222222'),
  'Priya Raman visited.', 'other users: their entries are untouched');
select is((select revision from public.notebooks where id = 'a1111111-0000-0000-0000-000000000002'), 5::bigint,
  'the rewrite does not bump a notebook''s revision');
select is((select source_revision from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000002'), 5::bigint,
  'so its card stays current');

set local role authenticated;
select is((select m ->> 'turnId' from jsonb_array_elements(
             (select public.get_entity_mentions('priya-nair')) -> 'mentions') m), null,
  'mentions still resolve (no turn for an entry-only line)');
select is((public.forget_entity('priya-raman', true) ->> 'transcriptPassages')::int, 0, 'a second erase changes nothing');

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is((public.forget_entity_preview('priya-raman') ->> 'transcriptPassages')::int, 2,
  'another user''s own preview counts only their passages');

select * from finish();
rollback;
