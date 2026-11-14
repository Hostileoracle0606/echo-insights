-- pgTAP: what the Phase 1 tickets must do together (R15). Run: supabase test db
--
-- LM-46's caps and LM-49's redaction were each tested on their own branch, and
-- the later migration silently replaced the earlier one. These checks hold
-- both behaviours in one call, plus the function attributes the redefinition
-- has to keep.
create extension if not exists pgtap;

begin;
select plan(31);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into public.notebooks (id, user_id, title, title_source, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N', 'auto', now(), 1, 'just_talk'),
  ('a1111111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'M', 'auto', now(), 1, 'just_talk');
insert into public.entities (id, user_id, notebook_id, name, type, mentions, first_seen, last_seen) values
  ('priya-shah', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Priya Shah', 'person', 1, now(), now());

create function public._t_card(p_rev bigint, p_note text)
returns jsonb language sql as $$
  select jsonb_build_object(
    'version', 1, 'notebookId', 'a1111111-0000-0000-0000-000000000001',
    'conversationMode', 'just_talk', 'sourceRevision', p_rev,
    'title', 't', 'summary', 's', 'remember', '[]'::jsonb,
    'notes', jsonb_build_array(p_note));
$$;
create function public._t_audio(n int) returns text language sql as $$
  select replace(encode(decode(repeat('00', n), 'hex'), 'base64'), E'\n', '');
$$;
create function public._t_turn(p_id text, p_name text)
returns jsonb language sql as $$
  select jsonb_build_object('kind', 'applyTurn',
    'entry', jsonb_build_object('text', 'hello', 'entityIds', jsonb_build_array(p_id)),
    'entities', jsonb_build_array(jsonb_build_object('id', p_id, 'name', p_name, 'type', 'person',
      'description', 'd', 'mentions', 1, 'questions', '[]'::jsonb)),
    'relations', '[]'::jsonb);
$$;
grant execute on function public._t_card(bigint, text), public._t_audio(int), public._t_turn(text, text)
  to authenticated;

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.forget_entity('priya-shah');

-- forgetting bumped N's revision to 2
select is((select revision from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  2::bigint, 'the notebook is at revision 2 after the forget');

-- ── save_session_card: caps and redaction in one function ──────────────────
select throws_ok(
  $$ select public.save_session_card('a1111111-0000-0000-0000-000000000001'::uuid, 2::bigint,
       public._t_card(2, repeat('x', 65536)), 't', 's') $$,
  '22023', null, 'card: over 64 KiB refused');
select throws_ok(
  $$ select public.save_session_card('a1111111-0000-0000-0000-000000000001'::uuid, 2::bigint,
       public._t_card(2, 'n'), repeat('t', 1001), 's') $$,
  '22023', 'title or summary is too long', 'card: a long title refused');
select throws_ok(
  $$ select public.save_session_card('a1111111-0000-0000-0000-000000000001'::uuid, null::bigint,
       public._t_card(2, 'n'), 't', 's') $$,
  '22023', 'source revision is required', 'card: a null revision refused');
select throws_ok(
  $$ select public.save_session_card('a1111111-0000-0000-0000-000000000001'::uuid, 2::bigint,
       '[]'::jsonb, 't', 's') $$,
  '22023', 'card must be an object', 'card: a non-object refused');

-- the name sits past the 60-character cut, and is the reason to redact first
select is(
  public.save_session_card('a1111111-0000-0000-0000-000000000001'::uuid, 2::bigint,
    public._t_card(2, 'Dinner with Priya Shah'),
    repeat('x', 49) || ' Priya Shah came by', 'Saw Priya Shah today')->>'status',
  'saved', 'card: an accepted card is saved');
select is(
  (select card->'notes'->>0 from public.session_cards
    where notebook_id = 'a1111111-0000-0000-0000-000000000001'),
  'Dinner with someone', 'card: the stored card is redacted');
select is(
  (select summary from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  'Saw someone today', 'card: the notebook summary is redacted');
select is(
  (select title from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  repeat('x', 49) || ' someone ca', 'card: the title is redacted before it is cut to 60');
select ok(
  (select title !~* 'priya' from public.notebooks where id = 'a1111111-0000-0000-0000-000000000001'),
  'card: no part of the name survives the cut');

-- ── save_session_brief: caps and the forgotten-name check in one function ──
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
       '{"openingLine":"Hi","focus":[],"openingThread":"t"}'::jsonb,
       repeat('A', 2796205), 24000) $$,
  '22023', null, 'brief: oversized audio refused');
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
       jsonb_build_object('openingLine', 'Hi', 'openingThread', repeat('t', 1001)),
       public._t_audio(4), 24000) $$,
  '22023', null, 'brief: a long openingThread refused');
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
       jsonb_build_object('openingLine', 'Hi', 'focus', '["a","b","c","d","e","f","g","h","i","j","k"]'::jsonb),
       public._t_audio(4), 24000) $$,
  '22023', null, 'brief: more than 10 focus items refused');
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
       '{"openingLine":"Hi"}'::jsonb, public._t_audio(4), 192001) $$,
  '22023', null, 'brief: sample rate over the cap refused');
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
       jsonb_build_object('openingLine', 'Priya Shah', 'openingThread', repeat('t', 1001)),
       public._t_audio(4), 24000) $$,
  '22023', null, 'brief: the caps come before the name check');
-- A name nested in a non-string focus item never reaches the name check.
select throws_ok(
  $$ select public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
       '{"openingLine":"Hi","focus":[{"who":"Priya Shah"}]}'::jsonb, public._t_audio(4), 24000) $$,
  '22023', null, 'brief: a non-string focus item is refused outright');
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
    '{"openingLine":"How is Priya Shah?"}'::jsonb, public._t_audio(4), 24000),
  '{"status":"unchanged"}'::jsonb, 'brief: one naming a forgotten person is not saved');
select is((select count(*) from public.session_briefs), 0::bigint, 'brief: nothing stored');
select is(
  public.save_session_brief('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
    '{"openingLine":"How was the walk?"}'::jsonb, public._t_audio(4), 24000),
  '{"status":"saved"}'::jsonb, 'brief: a clean one within the caps is saved');

-- ── commit_notebook: LM-46's caps in front of LM-49's _commit_apply_turn ───
select is(
  public.commit_notebook('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
    gen_random_uuid(), public._t_turn('priya-shah', repeat('n', 201)))->>'code',
  'invalidChange', 'commit: an oversized name is refused as data');
select is(
  public.commit_notebook('a1111111-0000-0000-0000-000000000002'::uuid, 1::bigint,
    gen_random_uuid(), public._t_turn('priya-shah', 'Priya Shah'))->>'status',
  'committed', 'commit: a turn naming a forgotten person commits');
select is(
  (select count(*) from public.entities where id = 'priya-shah'),
  0::bigint, 'commit: and does not bring the person back');

reset role;

-- ── the attributes the redefinition has to keep ────────────────────────────
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('save_session_card', 'save_session_brief', 'delete_empty_notebook')),
  3, 'one overload each: no signature changed');
select ok(
  (select bool_and(p.prosecdef and p.proconfig = array['search_path=public, pg_temp'])
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('save_session_card', 'save_session_brief', 'delete_empty_notebook')),
  'SECURITY DEFINER and search_path are kept');
select ok(has_function_privilege('authenticated', 'public.save_session_card(uuid, bigint, jsonb, text, text, boolean)', 'execute'),
  'authenticated can save a card');
select ok(not has_function_privilege('anon', 'public.save_session_card(uuid, bigint, jsonb, text, text, boolean)', 'execute'),
  'anon cannot save a card');
select ok(has_function_privilege('authenticated', 'public.save_session_brief(uuid, bigint, jsonb, text, int)', 'execute'),
  'authenticated can save a brief');
select ok(not has_function_privilege('anon', 'public.save_session_brief(uuid, bigint, jsonb, text, int)', 'execute'),
  'anon cannot save a brief');

-- ── profile columns are written only through their RPCs ────────────────────
select ok(
  not has_column_privilege('authenticated', 'public.profiles', c, 'update')
  and not has_column_privilege('authenticated', 'public.profiles', c, 'insert'),
  c || ' is not writable by a client')
from unnest(array['transcript_retention_days', 'transcript_retention_offered_at', 'privacy_screen_seen_at']) c;

select * from finish();
rollback;
