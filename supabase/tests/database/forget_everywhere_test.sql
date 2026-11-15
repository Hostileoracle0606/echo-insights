-- pgTAP: Forget everywhere (LM-63). After a forget, no read that feeds Lumen
-- returns the name, no graph payload carries it (ids included), the user's
-- own transcript keeps it, and Remove leaves unrelated cards current.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(53);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

-- U1: N1 holds Dana Whit under her own id and a foundation named after her;
-- N2 holds her again under a random id, and an "Archie" whose id is hers.
-- U2 has the same names and is never touched.
insert into public.notebooks (id, user_id, title, summary, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N1', 'S', now(), 3, 'just_talk'),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'N2', 'S', now(), 5, 'just_talk'),
  ('b2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'N', 'S', now(), 3, 'just_talk');

insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen) values
  ('dana-whit', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Dana Whit', 'person', 'My aunt', '{}', null, 2, now(), now()),
  ('dana-whit-foundation', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Dana Whit Foundation', 'organization', 'A charity', '{}', null, 1, now(), now()),
  ('someone-foundation', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Someone Foundation', 'organization', 'Already there', '{}', null, 4, now(), now()),
  ('dana-whit-foundation', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Dana Whit Foundation', 'organization', 'Same charity', '{}', null, 1, now(), now()),
  ('lena', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Lena', 'person', 'My friend', '{}', null, 1, now(), now()),
  ('e-1700000000000', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Dana Whit', 'person', 'Aunt again', '{}', null, 1, now(), now()),
  ('lena', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'Lena', 'person', 'Friend', '{}', null, 1, now(), now()),
  ('work', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'work', 'concept', 'my job', '{}', null, 1, now(), now()),
  ('dana-whit', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Dana Whit', 'person', 'U2''s Dana', '{}', null, 1, now(), now()),
  ('dana-whit-foundation', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Dana Whit Foundation', 'organization', null, '{}', null, 1, now(), now());

insert into public.relations (id, user_id, notebook_id, source_id, target_id, label, metadata) values
  ('dana-whit-foundation__funds__lena', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'dana-whit-foundation', 'lena', 'funds', '{}'),
  ('e-1700000000000__knows__lena', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'e-1700000000000', 'lena', 'knows', '{}'),
  ('dana-whit-foundation__funds__lena', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002', 'dana-whit-foundation', 'lena', 'funds', '{}');

insert into public.journal_entries (user_id, notebook_id, text, created_at, entity_ids, relation_ids) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'Dana Whit runs the Dana Whit Foundation with Lena.', now() - interval '2 hours',
   array['dana-whit', 'dana-whit-foundation', 'lena'], array['dana-whit-foundation__funds__lena']),
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002',
   'Lena saw dana whit at work. Lena is well.', now() - interval '1 hour',
   array['lena', 'e-1700000000000', 'work'], array['e-1700000000000__knows__lena']),
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002',
   'Lena and Lumen talked about the weather.', now(), array['lena'], '{}'),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001',
   'Dana Whit called.', now(), array['dana-whit'], '{}');

insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at) values
  ('a1111111-0000-0000-0000-000000000001', 't1', '11111111-1111-1111-1111-111111111111', 'user', 'Dana Whit runs the Dana Whit Foundation with Lena.', now() - interval '2 hours'),
  ('a1111111-0000-0000-0000-000000000001', 't2', '11111111-1111-1111-1111-111111111111', 'assistant', 'How long has Dana Whit run it?', now() - interval '2 hours'),
  ('a1111111-0000-0000-0000-000000000001', 't3', '11111111-1111-1111-1111-111111111111', 'user', 'Ages. Lena helps.', now() - interval '2 hours'),
  ('b2222222-0000-0000-0000-000000000001', 't1', '22222222-2222-2222-2222-222222222222', 'user', 'Dana Whit called.', now());

insert into public.follow_ups (user_id, notebook_id, question, reason, target_entity_ids) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'How is the charity doing?', '', array['dana-whit-foundation']);

-- N1's card is current and remembers the foundation; N2's is current and
-- remembers "work", which is removed below.
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'just_talk', 3,
   '{"version":1,"notebookId":"a1111111-0000-0000-0000-000000000001","conversationMode":"just_talk","sourceRevision":3,
     "title":"The charity","summary":"Lena helps a charity.","remember":[{"entityId":"dana-whit-foundation","name":"The charity"},{"entityId":"lena","name":"Lena"}],"notes":[]}'),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'just_talk', 5,
   '{"version":1,"notebookId":"a1111111-0000-0000-0000-000000000002","conversationMode":"just_talk","sourceRevision":5,
     "title":"Lena","summary":"Lena is well.","remember":[{"entityId":"work","name":"work"}],"notes":[]}');

-- Something in N1 that never names her, for the Remove check.
insert into public.entities (id, user_id, notebook_id, name, type, mentions, first_seen, last_seen) values
  ('garden', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'garden', 'concept', 1, now(), now());

create function public._t_as(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true);
$$;
grant execute on function public._t_as(uuid) to authenticated;

-- Everything a graph view or Lumen's context reads for a user, as one text.
create function public._t_reads(p_uid uuid) returns text language sql security definer as $$
  select concat_ws(' ',
    public.get_user_graph()::text,
    public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000001')::text,
    public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000002')::text,
    public.get_entity_mentions('lena')::text,
    public.get_entity_mentions('someone-foundation')::text,
    (select string_agg(coalesce(context_text, text), ' ') from public.conversation_turns where user_id = p_uid),
    (select string_agg(id || ' ' || name, ' ') from public.user_entities where user_id = p_uid),
    (select string_agg(id || ' ' || source_id || ' ' || target_id, ' ') from public.user_relations where user_id = p_uid));
$$;
grant execute on function public._t_reads(uuid) to authenticated;

-- ── Before anyone is forgotten, nothing is precomputed ─────────────────────
select is((select count(*)::int from public.journal_entries where context_text is not null), 0,
  'no context_text for a user who forgot no one');
select is((select count(*)::int from public.conversation_turns where context_text is not null), 0,
  'nor for their turns');

-- ── BUG-3: Remove leaves a current card current unless it remembers the entity ─
select public._t_as('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select is(public.remove_entity('garden'), '{"removedFrom": 1}'::jsonb, 'remove: garden goes');
reset role;
select is((select source_revision from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
          (select revision from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  'remove: N1''s card, which does not remember garden, is still current');
select is((select (card ->> 'sourceRevision')::bigint from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
          (select revision from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  'remove: and says so inside the card');
select public._t_as('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select is(public.remove_entity('work'), '{"removedFrom": 1}'::jsonb, 'remove: work goes');
reset role;
select is((select source_revision from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000002'), 5::bigint,
  'remove: N2''s card, which remembers work, is stale and will be rewritten');

-- ── Forget Dana Whit ───────────────────────────────────────────────────────
select public._t_as('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select is(public.forget_entity('dana-whit') ->> 'notebooks', '1', 'forget: she was in one notebook under her id');
reset role;

-- Ids that spell her name are rewritten (BUG-4).
select is((select array_agg(id order by notebook_id, id) from public.entities where user_id = '11111111-1111-1111-1111-111111111111'),
  array['lena', 'someone-foundation', 'lena', 'someone-foundation'],
  'ids: the foundation is someone-foundation in both notebooks, her duplicate is gone');
select is((select name from public.entities where notebook_id = 'a1111111-0000-0000-0000-000000000001' and id = 'someone-foundation'),
  'someone Foundation', 'ids: the renamed entity keeps its redacted name');
select is((select description from public.entities where notebook_id = 'a1111111-0000-0000-0000-000000000002' and id = 'someone-foundation'),
  'Already there', 'ids: where the new id was taken, the row already there stays');
select is((select array_agg(id || ':' || source_id || '>' || target_id order by notebook_id, id) from public.relations
           where user_id = '11111111-1111-1111-1111-111111111111'),
  array['someone-foundation__funds__lena:someone-foundation>lena', 'someone-foundation__funds__lena:someone-foundation>lena'],
  'ids: relations follow, ids and ends; the duplicate''s relation is gone');
select is((select entity_ids from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  array['someone-foundation', 'lena'], 'ids: provenance ids follow');
select is((select relation_ids from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  array['someone-foundation__funds__lena'], 'ids: provenance relation ids follow');
select is((select entity_ids from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000002'
           and text like 'Lena saw%'), array['lena'], 'ids: the duplicate''s id leaves the entries');
select is((select target_entity_ids from public.follow_ups where user_id = '11111111-1111-1111-1111-111111111111'),
  array['someone-foundation'], 'ids: a follow-up about the foundation stays, pointed at the new id');
select is((select card -> 'remember' -> 0 ->> 'entityId' from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'someone-foundation', 'ids: the card remembers the new id');
select is((select count(*)::int from public.entity_suppressions s where s.user_id = '11111111-1111-1111-1111-111111111111'
           and s.kind = 'removed' and s.entity_hash = public._suppression_hash('11111111-1111-1111-1111-111111111111', 'e-1700000000000')), 1,
  'duplicates: her other id is kept out as removed');
select is(public.redact_forgotten('11111111-1111-1111-1111-111111111111', 'E 1700000000000 and Lena'), 'E 1700000000000 and Lena',
  'duplicates: and is not redacted from text');

-- What Lumen reads of the user's words.
select is((select context_text from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'someone runs the someone Foundation with Lena.', 'words: an entry is redacted for Lumen');
select is((select text from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'Dana Whit runs the Dana Whit Foundation with Lena.', 'words: and stays verbatim for the user');
select is((select context_text from public.journal_entries where text like 'Lena saw%'),
  'Lena saw someone at work. Lena is well.', 'words: a lowercase full name is redacted too');
select is((select context_text from public.journal_entries where text like 'Lena and Lumen%'), null,
  'words: an entry that never named her has nothing precomputed');
select is((select array_agg(coalesce(context_text, '-') order by turn_id) from public.conversation_turns
           where user_id = '11111111-1111-1111-1111-111111111111'),
  array['someone runs the someone Foundation with Lena.', 'How long has someone run it?', '-'],
  'words: turns are redacted for Lumen, both speakers');
select is((select array_agg(text order by turn_id) from public.conversation_turns where user_id = '11111111-1111-1111-1111-111111111111'),
  array['Dana Whit runs the Dana Whit Foundation with Lena.', 'How long has Dana Whit run it?', 'Ages. Lena helps.'],
  'words: the transcript view still reads what was said');

select public._t_as('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select ok(position('dana' in lower(public._t_reads('11111111-1111-1111-1111-111111111111'))) = 0,
  'reads: no graph, snapshot, quote, turn context or view names her or spells her id');
select is(public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000001') -> 'state' -> 'entries' -> 0 ->> 'text',
  'someone runs the someone Foundation with Lena.', 'reads: the snapshot''s entry is the redacted one');
select is(public.get_entity_mentions('lena') -> 'mentions' -> -1 ->> 'excerpt',
  'someone runs the someone Foundation with Lena.', 'reads: a quote for another entity is the redacted one');
select is(public.get_entity_mentions('lena') -> 'mentions' -> -1 ->> 'turnId', 't1',
  'reads: and still finds the turn it came from');
select is(public.get_entity_mentions('lena') ->> 'total', '3', 'reads: every mention of Lena is still there');
select ok(public.get_user_graph() -> 'entities' @> '[{"id":"someone-foundation"}]', 'reads: the foundation is in the user graph');
select is((public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000001') ->> 'revision')::bigint,
          (select source_revision from public.session_cards where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'cards: forget leaves N1''s card current');

-- New words after the forget: precomputed on the way in.
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at)
  values ('a1111111-0000-0000-0000-000000000001', 't4', '11111111-1111-1111-1111-111111111111', 'user', 'DANA WHIT called again.', now());
select public._t_as('11111111-1111-1111-1111-111111111111');
set local role authenticated;
insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at, context_text)
  values ('a1111111-0000-0000-0000-000000000001', 't5', 'user', 'Dana Whit again.', now(), 'Dana Whit again.');
reset role;
select is((select context_text from public.conversation_turns where turn_id = 't4'), 'someone called again.',
  'new turn: redacted for Lumen on insert');
select is((select text from public.conversation_turns where turn_id = 't4'), 'DANA WHIT called again.',
  'new turn: kept for the user');
select is((select context_text from public.conversation_turns where turn_id = 't5'), 'someone again.',
  'new turn: a client cannot set what Lumen reads');

-- A commit after the forget: ids that spell her are rewritten on the way in.
select public.commit_notebook('a1111111-0000-0000-0000-000000000001',
  (public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000001') ->> 'revision')::bigint, gen_random_uuid(),
  jsonb_build_object('kind', 'applyTurn',
    'entry', jsonb_build_object('text', 'Dana Whit Park opened. Dana Whit Foundation paid. Dana Whit came.',
      'entityIds', jsonb_build_array('dana-whit-park', 'dana-whit-foundation', 'dana-whit'),
      'relationIds', jsonb_build_array('dana-whit-foundation__funds__dana-whit-park', 'dana-whit__visited__dana-whit-park')),
    'entities', jsonb_build_array(
      jsonb_build_object('id', 'dana-whit-park', 'name', 'Dana Whit Park', 'type', 'place', 'mentions', 1),
      jsonb_build_object('id', 'dana-whit-foundation', 'name', 'Dana Whit Foundation', 'type', 'organization', 'mentions', 2),
      jsonb_build_object('id', 'someone-foundation', 'name', 'Someone Foundation', 'type', 'organization', 'mentions', 3),
      jsonb_build_object('id', 'dana-whit', 'name', 'Dana Whit', 'type', 'person', 'mentions', 1)),
    'relations', jsonb_build_array(
      jsonb_build_object('id', 'dana-whit-foundation__funds__dana-whit-park', 'source', 'dana-whit-foundation',
                         'target', 'dana-whit-park', 'label', 'funds'),
      jsonb_build_object('id', 'dana-whit__visited__dana-whit-park', 'source', 'dana-whit',
                         'target', 'dana-whit-park', 'label', 'visited')),
    'askedQuestion', jsonb_build_object('question', 'Did you go to the park?', 'targetEntityIds', jsonb_build_array('dana-whit-park'))
  )) as c \gset
select is(:'c'::jsonb ->> 'status', 'committed', 'commit: lands');
select is((select array_agg(x order by x) from jsonb_array_elements_text(:'c'::jsonb -> 'suppressedIds') x),
  array['dana-whit', 'dana-whit-foundation', 'dana-whit-park'], 'commit: the device is told which of its ids are gone');
select is((select array_agg(id || '=' || name order by id) from public.entities where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  array['lena=Lena', 'someone-foundation=someone Foundation', 'someone-park=someone Park'],
  'commit: the park and foundation are stored under ids that do not spell her; she is not stored');
select is((select array_agg(id order by id) from public.relations where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  array['someone-foundation__funds__lena', 'someone-foundation__funds__someone-park'],
  'commit: a relation between two renamed ids is kept under the new ids; hers is dropped');
select is((select entity_ids from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000001' order by created_at desc limit 1),
  array['someone-park', 'someone-foundation'], 'commit: the entry points at the new ids');
select is((select context_text from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000001' order by created_at desc limit 1),
  'someone Park opened. someone Foundation paid. someone came.', 'commit: the entry''s words are redacted for Lumen');
select is((select target_entity_ids from public.asked_questions where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  array['someone-park'], 'commit: an asked question points at the new id');
select is((select count(*)::int from public.notebook_commit_requests where result::text ilike '%dana%'), 0,
  'commit: the ledger never stores an id that spells her');
select ok(position('dana' in lower(public._t_reads('11111111-1111-1111-1111-111111111111'))) = 0,
  'reads: still nothing names her after the commit');
reset role;

-- ── Over-redaction guards and isolation ────────────────────────────────────
select is((select name from public.entities where id = 'lena' and notebook_id = 'a1111111-0000-0000-0000-000000000001'), 'Lena',
  'guard: Lena is untouched');
select is((select count(*)::int from public.entity_suppressions where user_id = '11111111-1111-1111-1111-111111111111'
           and kind = 'forgotten'), 1, 'guard: only her slug is forgotten, not the ids that were renamed or removed');
select is(public.redact_forgotten('11111111-1111-1111-1111-111111111111', 'Someone Foundation and Dana Whitman'),
  'Someone Foundation and Dana Whitman', 'guard: whole names only');

select public._t_as('22222222-2222-2222-2222-222222222222');
set local role authenticated;
select ok(public.get_user_graph()::text like '%dana-whit-foundation%', 'isolation: U2''s foundation keeps its id');
select is(public.get_entity_mentions('dana-whit') -> 'mentions' -> 0 ->> 'excerpt', 'Dana Whit called.',
  'isolation: U2''s quotes are verbatim');
select is((select context_text from public.conversation_turns where notebook_id = 'b2222222-0000-0000-0000-000000000001'), null,
  'isolation: U2''s turns have nothing precomputed');
reset role;
select is((select count(*)::int from public.entities where user_id = '22222222-2222-2222-2222-222222222222'), 2,
  'isolation: U2''s graph is whole');

-- The precomputed words follow a later forget of someone else, too.
select public._t_as('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select public.forget_entity('lena') is not null as forgot_lena \gset
reset role;
select is((select context_text from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000001'
           and text like 'Dana Whit runs%'), 'someone runs the someone Foundation with someone.',
  'later forget: both names are redacted');
select is((select count(*)::int from public.conversation_turns where user_id = '11111111-1111-1111-1111-111111111111'
           and context_text is null and text ~* '(dana whit|lena)'), 0,
  'later forget: no turn that names either is left without its redacted words');

select * from finish();
rollback;
