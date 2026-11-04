-- pgTAP: size caps and type checks on the write RPCs (LM-46).
-- Run: supabase test db
--
-- Each cap is tested just under (accepted) and just over (22023). The
-- messages are checked to carry no user content.
create extension if not exists pgtap;

begin;
select plan(41);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into public.notebooks (id, user_id, title, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N', now(), 0, 'just_talk');

create function public._t_brief(p_focus jsonb, p_thread jsonb, p_line text)
returns jsonb language sql as $$
  select jsonb_build_object('focus', p_focus, 'openingThread', p_thread, 'openingLine', p_line);
$$;
-- base64 of n zero bytes
create function public._t_audio(n int) returns text language sql as $$
  select replace(encode(decode(repeat('00', n), 'hex'), 'base64'), E'\n', '');
$$;
create function public._t_card(p_rev bigint, p_extra text default '')
returns jsonb language sql as $$
  select jsonb_build_object(
    'version', 1, 'notebookId', 'a1111111-0000-0000-0000-000000000001',
    'conversationMode', 'just_talk', 'sourceRevision', p_rev,
    'title', 't', 'summary', 's', 'remember', '[]'::jsonb,
    'notes', jsonb_build_array(p_extra));
$$;
grant execute on function public._t_brief(jsonb, jsonb, text), public._t_audio(int),
  public._t_card(bigint, text) to authenticated;

create function public._t_turn(p_entity jsonb, p_text text default 'hello')
returns jsonb language sql as $$
  select jsonb_build_object('kind', 'applyTurn',
    'entry', jsonb_build_object('text', p_text, 'entityIds', jsonb_build_array(p_entity->>'id')),
    'entities', jsonb_build_array(p_entity), 'relations', '[]'::jsonb);
$$;
grant execute on function public._t_turn(jsonb, text) to authenticated;
create function public._t_ent(p_name text, p_desc text default 'd', p_questions jsonb default '[]'::jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('id', 'e1', 'name', p_name, 'type', 'person', 'description', p_desc,
    'mentions', 1, 'questions', p_questions);
$$;
grant execute on function public._t_ent(text, text, jsonb) to authenticated;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── save_session_brief ─────────────────────────────────────────────────────
select is((public.save_session_brief('a1111111-0000-0000-0000-000000000001', 1,
    public._t_brief('["a"]'::jsonb, '"t"'::jsonb, 'Hi'), public._t_audio(2097152), 24000))->>'status',
  'saved', 'brief: audio of exactly 2 MiB is accepted');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 2,
    public._t_brief('["a"]'::jsonb, '"t"'::jsonb, 'Hi'), public._t_audio(2097153), 24000) $$,
  '22023', 'audio is too large (max 2097152 bytes)', 'brief: audio one byte over 2 MiB is refused');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 2,
    public._t_brief('["a"]'::jsonb, '"t"'::jsonb, 'Hi'), repeat('A', 2796208), 24000) $$,
  '22023', 'audio is too large (max 2097152 bytes)', 'brief: oversized base64 text is refused before decoding');

select is((public.save_session_brief('a1111111-0000-0000-0000-000000000001', 3,
    public._t_brief('["a","b","c","d","e","f","g","h","i","j"]'::jsonb, '"t"'::jsonb, 'Hi'),
    public._t_audio(100), 24000))->>'status', 'saved', 'brief: 10 focus items accepted');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 4,
    public._t_brief('["a","b","c","d","e","f","g","h","i","j","k"]'::jsonb, '"t"'::jsonb, 'Hi'),
    public._t_audio(100), 24000) $$,
  '22023', 'focus must have at most 10 items', 'brief: 11 focus items refused');
select is((public.save_session_brief('a1111111-0000-0000-0000-000000000001', 5,
    public._t_brief(jsonb_build_array(repeat('x', 500)), '"t"'::jsonb, 'Hi'),
    public._t_audio(100), 24000))->>'status', 'saved', 'brief: a 500-char focus item accepted');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 6,
    public._t_brief(jsonb_build_array(repeat('x', 501)), '"t"'::jsonb, 'Hi'),
    public._t_audio(100), 24000) $$,
  '22023', 'focus items must be strings of at most 500 characters', 'brief: a 501-char focus item refused');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 6,
    public._t_brief('[1]'::jsonb, '"t"'::jsonb, 'Hi'), public._t_audio(100), 24000) $$,
  '22023', 'focus items must be strings of at most 500 characters', 'brief: a non-string focus item refused');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 6,
    public._t_brief('{"a":1}'::jsonb, '"t"'::jsonb, 'Hi'), public._t_audio(100), 24000) $$,
  '22023', 'focus must be an array', 'brief: focus that is not an array refused');

select is((public.save_session_brief('a1111111-0000-0000-0000-000000000001', 7,
    public._t_brief('["a"]'::jsonb, to_jsonb(repeat('x', 1000)), 'Hi'),
    public._t_audio(100), 24000))->>'status', 'saved', 'brief: a 1000-char openingThread accepted');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 8,
    public._t_brief('["a"]'::jsonb, to_jsonb(repeat('x', 1001)), 'Hi'),
    public._t_audio(100), 24000) $$,
  '22023', 'openingThread must be at most 1000 characters', 'brief: a 1001-char openingThread refused');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 8,
    public._t_brief('["a"]'::jsonb, '123'::jsonb, 'Hi'), public._t_audio(100), 24000) $$,
  '22023', 'openingThread must be a string', 'brief: a non-string openingThread refused');

select is((public.save_session_brief('a1111111-0000-0000-0000-000000000001', 9,
    public._t_brief('["a"]'::jsonb, '"t"'::jsonb, repeat('x', 160)),
    public._t_audio(100), 24000))->>'status', 'saved', 'brief: a 160-char openingLine accepted');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 10,
    public._t_brief('["a"]'::jsonb, '"t"'::jsonb, repeat('x', 161)),
    public._t_audio(100), 24000) $$,
  '22023', 'openingLine must be 1 to 160 characters', 'brief: a 161-char openingLine refused');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 10,
    '{"focus":[],"openingThread":"t","openingLine":5}'::jsonb, public._t_audio(100), 24000) $$,
  '22023', 'openingLine must be 1 to 160 characters', 'brief: a non-string openingLine refused');

select is((public.save_session_brief('a1111111-0000-0000-0000-000000000001', 11,
    public._t_brief('["a"]'::jsonb, '"t"'::jsonb, 'Hi'),
    public._t_audio(100), 192000))->>'status', 'saved', 'brief: sample rate 192000 accepted');
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 12,
    public._t_brief('["a"]'::jsonb, '"t"'::jsonb, 'Hi'), public._t_audio(100), 192001) $$,
  '22023', 'sample rate must be between 1 and 192000', 'brief: sample rate 192001 refused');

select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', null,
    public._t_brief('["a"]'::jsonb, '"t"'::jsonb, 'Hi'), public._t_audio(100), 24000) $$,
  '22023', 'source revision is required', 'brief: a null revision raises 22023, not 23502');

-- error messages never echo the input
select throws_ok($$ select public.save_session_brief('a1111111-0000-0000-0000-000000000001', 12,
    public._t_brief('["a"]'::jsonb, to_jsonb('SECRET-THREAD-' || repeat('x', 1001)), 'Hi'),
    public._t_audio(100), 24000) $$,
  '22023', 'openingThread must be at most 1000 characters', 'brief: the message does not contain the content');

-- ── save_session_card ──────────────────────────────────────────────────────
select is((public.save_session_card('a1111111-0000-0000-0000-000000000001', 0,
    public._t_card(0), 'T', 'S'))->>'status', 'saved', 'card: a normal card is saved');
select throws_ok($$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', null,
    public._t_card(0), 'T', 'S') $$,
  '22023', 'source revision is required', 'card: a null revision raises 22023');
select throws_ok($$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', null,
    public._t_card(0), 'T', 'S', true) $$,
  '22023', 'source revision is required', 'card: a null revision raises 22023 for a draft too');
select throws_ok($$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', 0,
    '[]'::jsonb, 'T', 'S') $$,
  '22023', 'card must be an object', 'card: a non-object card refused');

-- Size is the whole card as text: pad the one note to land exactly on the limit.
select is((public.save_session_card('a1111111-0000-0000-0000-000000000001', 0,
    public._t_card(0, repeat('x', 65536 - octet_length(public._t_card(0, '')::text))), 'T', 'S'))->>'status',
  'saved', 'card: exactly 64 KiB accepted');
select throws_ok($$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', 0,
    public._t_card(0, repeat('x', 65537 - octet_length(public._t_card(0, '')::text))), 'T', 'S') $$,
  '22023', 'card is too large (max 65536 bytes)', 'card: one byte over 64 KiB refused');

select is((public.save_session_card('a1111111-0000-0000-0000-000000000001', 0,
    public._t_card(0), repeat('t', 1000), repeat('s', 1000)))->>'status',
  'saved', 'card: 1000-char title and summary accepted (then cut to 60/280)');
select throws_ok($$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', 0,
    public._t_card(0), repeat('t', 1001), 'S') $$,
  '22023', 'title or summary is too long', 'card: a 1001-char title refused');
select throws_ok($$ select public.save_session_card('a1111111-0000-0000-0000-000000000001', 0,
    public._t_card(0), 'T', repeat('s', 1001)) $$,
  '22023', 'title or summary is too long', 'card: a 1001-char summary refused');

-- ── commit_notebook ────────────────────────────────────────────────────────
select is((public.commit_notebook('a1111111-0000-0000-0000-000000000001', 0, gen_random_uuid(),
    public._t_turn(public._t_ent(repeat('n', 200), repeat('d', 2000),
      (select jsonb_agg(repeat('q', 500)) from generate_series(1, 20))))))->>'status',
  'committed', 'commit: entity at every limit is accepted');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 1, gen_random_uuid(),
    public._t_turn(public._t_ent(repeat('n', 201)))) $$,
  '22023', 'an entity exceeds its field limits', 'commit: a 201-char entity name refused');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 1, gen_random_uuid(),
    public._t_turn(public._t_ent('n', repeat('d', 2001)))) $$,
  '22023', 'an entity exceeds its field limits', 'commit: a 2001-char description refused');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 1, gen_random_uuid(),
    public._t_turn(public._t_ent('n', 'd', (select jsonb_agg('q'::text) from generate_series(1, 21))))) $$,
  '22023', 'an entity exceeds its field limits', 'commit: 21 entity questions refused');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 1, gen_random_uuid(),
    public._t_turn(public._t_ent('n', 'd', jsonb_build_array(repeat('q', 501))))) $$,
  '22023', 'an entity exceeds its field limits', 'commit: a 501-char question refused');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 1, gen_random_uuid(),
    public._t_turn(public._t_ent('n', 'd', '[1]'::jsonb))) $$,
  '22023', 'an entity exceeds its field limits', 'commit: a non-string question refused');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 1, gen_random_uuid(),
    '{"kind":"applyTurn","entry":{"text":"x"},"entities":{"a":1}}'::jsonb) $$,
  '22023', 'entities must be an array', 'commit: entities that is not an array refused');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 1, gen_random_uuid(),
    '[1]'::jsonb) $$,
  '22023', 'change must be an object', 'commit: a non-object change refused');

-- Whole-change size: an entry just under and just over 256 KiB as text. The
-- entry text itself is only allowed 8000 chars, so pad with an unused key.
select is((public.commit_notebook('a1111111-0000-0000-0000-000000000001', 1, gen_random_uuid(),
    jsonb_build_object('kind', 'clearNotebook', 'pad', repeat('x', 262144 - 38))))->>'status',
  'committed', 'commit: a change just under 256 KiB is accepted');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 2, gen_random_uuid(),
    jsonb_build_object('kind', 'clearNotebook', 'pad', repeat('x', 262144))) $$,
  '22023', 'change is too large (max 262144 bytes)', 'commit: a change over 256 KiB refused');

-- relation label and follow-up text
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 2, gen_random_uuid(),
    jsonb_build_object('kind', 'applyTurn', 'entry', jsonb_build_object('text', 'x'),
      'relations', jsonb_build_array(jsonb_build_object('id','r','source','a','target','b','label', repeat('l', 201))))) $$,
  '22023', 'a relation label is too long', 'commit: a 201-char relation label refused');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 2, gen_random_uuid(),
    jsonb_build_object('kind', 'applyTurn', 'entry', jsonb_build_object('text', 'x'),
      'followUp', jsonb_build_object('question', repeat('q', 1001)))) $$,
  '22023', 'followUp text is too long', 'commit: a 1001-char follow-up question refused');
select throws_ok($$ select public.commit_notebook('a1111111-0000-0000-0000-000000000001', 2, gen_random_uuid(),
    jsonb_build_object('kind', 'applyTurn', 'entry', jsonb_build_object('text', 'x'),
      'askedQuestion', 'oops')) $$,
  '22023', 'askedQuestion must be an object', 'commit: a non-object askedQuestion refused');

select * from finish();
rollback;
