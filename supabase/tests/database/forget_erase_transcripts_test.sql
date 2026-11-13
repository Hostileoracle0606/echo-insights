-- pgTAP: Forget with "also erase them from my saved transcripts".
--
-- R34: only names of two or more words can be erased (a one-word name would
-- rewrite ordinary words: "Will you come?"); the server refuses the rest with
-- 22023. Only the name as saved is matched: "Maya" alone stays when "Maya
-- Chen" is erased (the forget matcher's existing rule).
-- R35: forget_entity(id, true) commits the forget and queues an erase job;
-- forget_erase_step rewrites a bounded batch per call and says how many rows
-- are left to check. LM-63's trigger keeps context_text consistent with text.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(55);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into public.notebooks (id, user_id, title, summary, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N1', 'S', now(), 3, 'just_talk'),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'N2', 'S', now(), 5, 'just_talk'),
  ('b2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'N', 'S', now(), 3, 'just_talk');

insert into public.entities (id, user_id, notebook_id, name, type, description, metadata, questions, mentions, first_seen, last_seen) values
  ('maya-chen', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Maya Chen', 'person', null, '{}', null, 1, now(), now()),
  ('will', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Will', 'person', null, '{}', null, 1, now(), now()),
  ('priya-nair', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Priya Nair', 'person', null, '{}', null, 1, now(), now()),
  ('work', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'work', 'topic', null, '{}', null, 1, now(), now()),
  ('sam', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Sam', 'person', null, '{}', null, 1, now(), now()),
  ('maya-chen', '22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Maya Chen', 'person', null, '{}', null, 1, now(), now());

insert into public.journal_entries (user_id, notebook_id, text, created_at, entity_ids) values
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001',
   'Maya Chen called. Work was fine.', now(), array['maya-chen', 'work']),
  ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000002',
   'Lunch with Priya Nair.', now(), array['priya-nair']),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001',
   'Maya Chen visited.', now(), array['maya-chen']);

insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at)
  select 'a1111111-0000-0000-0000-000000000002', 'bulk-' || lpad(g::text, 3, '0'), '11111111-1111-1111-1111-111111111111',
         'user', 'Turn ' || g || ': Maya Chen said hi.', now() - make_interval(secs => 1000 - g)
  from generate_series(1, 600) g;
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at) values
  ('a1111111-0000-0000-0000-000000000001', 't1', '11111111-1111-1111-1111-111111111111', 'user', 'Maya Chen called. Work was fine.', now()),
  ('a1111111-0000-0000-0000-000000000001', 't2', '11111111-1111-1111-1111-111111111111', 'assistant', 'How is Maya Chen?', now()),
  ('a1111111-0000-0000-0000-000000000001', 't3', '11111111-1111-1111-1111-111111111111', 'user', 'Maya is fine, said Maya.', now()),
  ('a1111111-0000-0000-0000-000000000001', 't4', '11111111-1111-1111-1111-111111111111', 'user', 'Sam and Maya Chen talked.', now()),
  ('a1111111-0000-0000-0000-000000000001', 'w1', '11111111-1111-1111-1111-111111111111', 'user', 'Will you come?', now()),
  ('a1111111-0000-0000-0000-000000000001', 'w2', '11111111-1111-1111-1111-111111111111', 'user', 'WILL is a strong word.', now()),
  ('a1111111-0000-0000-0000-000000000001', 'w3', '11111111-1111-1111-1111-111111111111', 'user', 'Free Will is a big topic.', now()),
  ('a1111111-0000-0000-0000-000000000001', 'w4', '11111111-1111-1111-1111-111111111111', 'user', 'Will Smith was on TV.', now()),
  ('a1111111-0000-0000-0000-000000000001', 'w5', '11111111-1111-1111-1111-111111111111', 'user', 'It takes will-power.', now()),
  ('a1111111-0000-0000-0000-000000000002', 'x1', '11111111-1111-1111-1111-111111111111', 'user', 'we met maya chen downtown.', now()),
  ('b2222222-0000-0000-0000-000000000001', 'u1', '22222222-2222-2222-2222-222222222222', 'user', 'Maya Chen visited.', now());

insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card) values
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'just_talk', 5,
   '{"title":"T","summary":"Lunch.","notes":[],"remember":[],"sourceRevision":5}');

create temp table steps (n int, result jsonb);
grant all on steps to authenticated;

-- ── who may call it ────────────────────────────────────────────────────────
set local role anon;
select throws_ok($$select public.forget_entity('maya-chen', true)$$, '42501', null, 'anon cannot erase');
select throws_ok($$select public.forget_erase_step(gen_random_uuid(), 100)$$, '42501', null, 'anon cannot step an erase');
select throws_ok($$select public.forget_erase_sample('maya-chen')$$, '42501', null, 'anon cannot read a sample');
select throws_ok($$select public.forget_erase_pending()$$, '42501', null, 'anon cannot list erases');
set local role authenticated;
select throws_ok($$select public.forget_entity('maya-chen', true)$$, '42501', null, 'no caller, no erase');
select throws_ok($$select public.forget_erase_step(gen_random_uuid(), 100)$$, '42501', null, 'no caller, no step');
select throws_ok($$select count(*) from public.forget_erase_jobs$$, '42501', null,
  'the job table is not readable by clients (it holds the name until done)');

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.remove_entity('work');
-- Sam is forgotten first, without erasing: the erase must leave his name in
-- text while context_text keeps redacting it.
select public.forget_entity('sam');

-- ── R34: one-word names ────────────────────────────────────────────────────
select is(public.forget_entity_preview('will') -> 'eraseAvailable', 'false'::jsonb,
  'preview: a one-word name cannot be erased');
select is(public.forget_erase_sample('will'), '{"available":false,"passages":[]}'::jsonb,
  'sample: nothing for a one-word name');
select throws_ok($$select public.forget_entity('will', true)$$, '22023', null,
  'the server refuses a one-word-name erase');
select is((select count(*)::int from public.entities where id = 'will'), 1,
  'the refused call forgot nothing (the forget and the erase are one request)');
select is((select string_agg(text, ' | ' order by turn_id) from public.conversation_turns where turn_id like 'w%'),
  'Will you come? | WILL is a strong word. | Free Will is a big topic. | Will Smith was on TV. | It takes will-power.',
  'refused: "Will you…", "WILL", "Free Will", "Will Smith", "will-power" are untouched');
select is(public.forget_entity('will', false) ? 'eraseJobId', false, 'a plain forget of Will still works');
select is((select text from public.conversation_turns where turn_id = 'w4'), 'Will Smith was on TV.',
  'plain forget: the transcript keeps the words (LM-63)');

-- ── preview and sample for a two-word name ─────────────────────────────────
select is(public.forget_entity_preview('maya-chen') -> 'eraseAvailable', 'true'::jsonb,
  'preview: a two-word name can be erased');
select is((public.forget_entity_preview('maya-chen') ->> 'transcriptPassages')::int, 500,
  'preview: the count stops at 500 (604 rows name her)');
select is(public.forget_entity_preview('maya-chen') -> 'transcriptPassagesCapped', 'true'::jsonb,
  'preview: and says it stopped');
select is(jsonb_array_length(public.forget_erase_sample('maya-chen') -> 'passages'), 3,
  'sample: three passages by default');
select ok((select bool_and(p ->> 'before' ilike '%Maya Chen%' and p ->> 'after' like '%someone%'
                           and p ->> 'after' not ilike '%Maya Chen%')
           from jsonb_array_elements(public.forget_erase_sample('maya-chen') -> 'passages') p),
  'sample: each passage before (with the name) and after (with "someone")');
select is(jsonb_array_length(public.forget_erase_sample('maya-chen', 50) -> 'passages'), 5,
  'sample: at most 5');
select is(public.forget_erase_sample('maya-chen') -> 'passages' -> 0 ->> 'before', 'we met maya chen downtown.',
  'sample: a match not written as saved ("maya chen") comes first, the riskier kind');

-- ── R35: the forget commits, the erase is queued ───────────────────────────
create temp table job (id uuid);
grant all on job to authenticated;
insert into job select (public.forget_entity('maya-chen', true) ->> 'eraseJobId')::uuid;
select isnt((select id from job), null, 'erase on: the forget returns a job');
select is((select count(*)::int from public.entities where id = 'maya-chen' and user_id = '11111111-1111-1111-1111-111111111111'), 0,
  'the forget itself is done');
select is((select text from public.conversation_turns where turn_id = 't1'), 'Maya Chen called. Work was fine.',
  'no transcript is rewritten by the forget call');
select is((select context_text from public.conversation_turns where turn_id = 't1'), 'someone called. Work was fine.',
  'Lumen already reads it redacted (LM-63)');
select is((select jsonb_agg(p ->> 'id') from jsonb_array_elements(public.forget_erase_pending()) p),
  (select jsonb_agg(id::text) from job), 'the job is pending for its owner');

-- The job holds no readable name, and no unkeyed hash of one.
reset role;
select ok((select row_to_json(j)::text from public.forget_erase_jobs j) !~* '(maya|chen)',
  'no job column holds the name or its slug');
select ok(not exists (
  select 1 from public.forget_erase_jobs j,
         unnest(j.hashes) h
   where h = encode(extensions.hmac(convert_to('maya-chen', 'UTF8'), '\x00'::bytea, 'sha256'), 'hex')),
  'no zero-key (unkeyed) hash is stored');
select is((select hashes from public.forget_erase_jobs),
  array[public._suppression_hash('11111111-1111-1111-1111-111111111111', 'maya-chen')],
  'the job holds the keyed hash of each name to erase');
select isnt((select cutoff from public.forget_erase_jobs), null, 'and the time of the forget');
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- Another user can neither see nor run it.
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is(public.forget_erase_pending(), '[]'::jsonb, 'another user sees no pending erase');
select is(public.forget_erase_step((select id from job), 1000) -> 'finished', 'true'::jsonb,
  'another user''s step finds no job');
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select is((select text from public.conversation_turns where turn_id = 'bulk-001'), 'Turn 1: Maya Chen said hi.',
  'and changes nothing');

-- Steps of 100 rows.
insert into steps select 1, public.forget_erase_step((select id from job), 100);
select is((select result -> 'finished' from steps where n = 1), 'false'::jsonb, 'the first step is not the last');
select cmp_ok((select (result ->> 'remaining')::int from steps where n = 1), '>', 0, 'and says how many rows are left to check');

-- Saved after the forget: one in a notebook already passed (N1), one in a
-- notebook not yet reached (N2's turns sort before 'zz').
reset role;
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at, created_at) values
  ('a1111111-0000-0000-0000-000000000001', 'late-1', '11111111-1111-1111-1111-111111111111', 'user',
   'Maya Chen again, later.', now(), now() + interval '1 minute'),
  ('a1111111-0000-0000-0000-000000000002', 'zz-late', '11111111-1111-1111-1111-111111111111', 'user',
   'Maya Chen again, much later.', now(), now() + interval '1 minute');
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
declare i int := 2;
begin
  loop
    insert into steps select i, public.forget_erase_step((select id from job), 100);
    exit when (select (result ->> 'finished')::boolean from steps where n = i) or i > 50;
    i := i + 1;
  end loop;
end $$;
select ok((select (result ->> 'finished')::boolean and (result ->> 'remaining')::int = 0
           from steps order by n desc limit 1), 'the steps finish, with 0 remaining');
select is((select sum((result ->> 'rewritten')::int)::int from steps), 605,
  'every turn and entry that named her when she was forgotten was rewritten once');
select ok(not exists (select 1 from steps where (result ->> 'remaining')::int = 0
                                            and not (result ->> 'finished')::boolean),
  'no step says 0 remaining without being finished');
select ok((select bool_and((result ->> 'remaining')::int >= 0) from steps), 'remaining never goes negative');
select is(public.forget_erase_pending(), '[]'::jsonb, 'a finished job is gone (with the name it held)');
select is(public.forget_erase_step((select id from job), 100) ->> 'rewritten', '0', 'a step after the end does nothing');

reset role;
select is((select count(*)::int from public.forget_erase_jobs), 0, 'no job row is left');
select is((select count(*)::int from public.conversation_turns
           where user_id = '11111111-1111-1111-1111-111111111111' and text like '%Maya Chen%'
             and turn_id not like '%late%'), 0,
  'turns: none of the caller''s names her, across notebooks and batches');
select is((select text from public.conversation_turns where turn_id = 'x1'), 'we met someone downtown.',
  'turns: a lowercase match is erased too');
select is((select string_agg(text, ' | ' order by turn_id) from public.conversation_turns where turn_id like '%late%'),
  'Maya Chen again, later. | Maya Chen again, much later.',
  'turns saved after the forget are not erased, in a passed notebook or one not yet reached');
select is((select text from public.conversation_turns where turn_id = 'bulk-600'), 'Turn 600: someone said hi.',
  'turns: the last batch is rewritten');
select is((select text from public.conversation_turns where turn_id = 't2'), 'How is someone?', 'turns: Lumen''s turns too');
select is((select text from public.conversation_turns where turn_id = 't3'), 'Maya is fine, said Maya.',
  'turns: "Maya" alone stays (only the name as saved is matched)');
select is((select text from public.conversation_turns where turn_id = 'w4'), 'Will Smith was on TV.',
  'turns: Will Smith is untouched');
select is((select text from public.journal_entries where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'someone called. Work was fine.', 'entries: her name goes, the removed word "Work" stays');
select is((select text from public.conversation_turns where turn_id = 't4'), 'Sam and someone talked.',
  'turns: only her name is erased, not another forgotten person''s');
select is((select context_text from public.conversation_turns where turn_id = 't4'), 'someone and someone talked.',
  'context_text: recomputed from the new text, still redacting Sam');
select is((select count(*)::int from public.conversation_turns
           where user_id = '11111111-1111-1111-1111-111111111111'
             and context_text is distinct from public._context_text(user_id, text)
             and turn_id not like '%late%'), 0,
  'context_text matches text on every turn of the caller''s');
select is((select text from public.conversation_turns where turn_id = 'u1'), 'Maya Chen visited.',
  'other users: their turns are untouched');
select is((select revision from public.notebooks where id = 'a1111111-0000-0000-0000-000000000002'), 5::bigint,
  'the erase does not bump a notebook''s revision, so its card stays current');

select * from finish();
rollback;
