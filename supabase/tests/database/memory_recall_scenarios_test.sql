-- Cross-feature scenario test: session memory and recall across a chain of
-- sessions, with every Phase 1 privacy feature applied. Run: supabase test db
--
-- One user (U1) has sessions S1, S2, S3 (off the record) and S4. After each
-- step the test asks what the NEXT session would recall, through the same
-- RPCs the app and the retrieve-memory edge function call, with the user's JWT
-- claims:
--   get_user_graph / user_entities / get_entity_mentions   user-level memory
--   get_notebook_snapshot                                  a notebook's own state
--   match_user_entity_embeddings (service role)            semantic seeds
--   get_session_brief                                      the opening brief
--   session_cards                                          the closing cards
-- A second user (U2) holds look-alike data (the same slugs, "Priya Raman" and
-- "Halvorsen Group" included) and is checked at every step in both directions.
--
-- Steps:   1 baseline   2 continuity   3 off the record   4 auto-forget
--          5 remove vs forget           6 delete a session  7 isolation (throughout)
--
-- Limits: embed-entities (Supabase.ai gte-small) is not running here, so the
-- test writes the embedding rows the way embed-entities does, and checks the
-- trigger QUEUED the job (pg_net, with Vault config). Close-session, brief
-- generation and Gemini are Lambdas: the test calls the RPCs they call.
--
-- Failures marked TODO below are product bugs found by this suite, not wrong
-- assumptions. See the report for each.
create extension if not exists pgtap;

begin;
select plan(307);

-- ── helpers (live only in this rolled-back transaction) ─────────────────────
create function public._t_as(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
           jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true);
$$;

create function public._t_ent(p_id text, p_name text, p_type text, p_desc text default null,
  p_mentions int default 1, p_meta jsonb default '{}', p_q jsonb default null,
  p_seen timestamptz default now()) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', p_id, 'name', p_name, 'type', p_type, 'description', p_desc, 'metadata', p_meta,
    'mentions', p_mentions, 'firstSeen', p_seen, 'lastSeen', p_seen, 'questions', p_q));
$$;

create function public._t_rel(p_src text, p_label text, p_tgt text, p_meta jsonb default '{}',
  p_at timestamptz default now()) returns jsonb language sql as $$
  select jsonb_build_object('id', p_src || '__' || p_label || '__' || p_tgt, 'source', p_src,
    'target', p_tgt, 'label', p_label, 'metadata', p_meta, 'createdAt', p_at);
$$;

-- One applyTurn commit, at the revision a fresh snapshot reports, as the app does.
create function public._t_commit(p_nb uuid, p_text text, p_entities jsonb, p_relations jsonb,
  p_follow jsonb default null, p_asked jsonb default null) returns jsonb language plpgsql as $$
declare
  v_rev bigint := (public.get_notebook_snapshot(p_nb) ->> 'revision')::bigint;
begin
  return public.commit_notebook(p_nb, v_rev, gen_random_uuid(), jsonb_strip_nulls(jsonb_build_object(
    'kind', 'applyTurn',
    'entry', jsonb_build_object('text', p_text,
      'entityIds', (select coalesce(jsonb_agg(e ->> 'id'), '[]') from jsonb_array_elements(p_entities) e),
      'relationIds', (select coalesce(jsonb_agg(r ->> 'id'), '[]') from jsonb_array_elements(p_relations) r)),
    'entities', p_entities, 'relations', p_relations,
    'followUp', p_follow, 'askedQuestion', p_asked)));
end $$;

create function public._t_turn(p_nb uuid, p_id text, p_speaker text, p_text text)
returns void language sql as $$
  insert into public.conversation_turns (notebook_id, turn_id, speaker, text, spoken_at)
  values (p_nb, p_id, p_speaker, p_text, now());
$$;

-- What close-session writes: a card for the notebook's current revision.
create function public._t_card(p_nb uuid, p_title text, p_summary text, p_remember jsonb, p_notes jsonb)
returns jsonb language plpgsql as $$
declare
  v_rev bigint := (public.get_notebook_snapshot(p_nb) ->> 'revision')::bigint;
begin
  return public.save_session_card(p_nb, v_rev, jsonb_build_object(
    'version', 1, 'notebookId', p_nb, 'conversationMode', 'just_talk', 'sourceRevision', v_rev,
    'generatedAt', '2026-11-01T12:00:00Z', 'title', p_title, 'summary', p_summary,
    'remember', p_remember, 'notes', p_notes), p_title, p_summary);
end $$;

-- What the brief runtime writes: a brief and its (fake) opening audio.
create function public._t_brief(p_nb uuid, p_line text, p_thread text, p_focus jsonb)
returns jsonb language plpgsql as $$
declare
  v_rev bigint := (public.get_notebook_snapshot(p_nb) ->> 'revision')::bigint;
begin
  return public.save_session_brief(p_nb, v_rev, jsonb_build_object(
    'openingLine', p_line, 'openingThread', p_thread, 'focus', p_focus), 'AAAAAAAA', 24000);
end $$;

-- A unit vector per entity id, so a query for an id finds exactly that entity.
create function public._t_vec(p_id text) returns vector language sql immutable as $$
  select (array(select (case when i = (abs(hashtext(p_id)) % 384) + 1 then 1 else 0 end)::real
                from generate_series(1, 384) i))::vector(384);
$$;

-- What embed-entities does for a user: embed an entity that has no row, or
-- whose text changed.
create function public._t_embed(p_uid uuid) returns void language sql security definer
set search_path = public, pg_temp as $$
  insert into public.entity_embeddings
    (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
  select e.notebook_id, e.id, e.user_id, public._t_vec(e.id), 'gte-small',
         md5(coalesce(e.name, '') || '|' || coalesce(e.description, '') || '|' || coalesce(e.metadata::text, ''))
  from public.entities e where e.user_id = p_uid
  on conflict (notebook_id, entity_id) do update
    set embedding = excluded.embedding, content_hash = excluded.content_hash, updated_at = now()
    where public.entity_embeddings.content_hash is distinct from excluded.content_hash;
$$;

-- The user-level graph, as the next session's retrieval reads it.
create function public._t_graph_ids() returns text[] language sql stable as $$
  select coalesce(array_agg(e ->> 'id' order by e ->> 'id'), '{}')
  from jsonb_array_elements(public.get_user_graph() -> 'entities') e;
$$;

create function public._t_graph_ent(p_id text) returns jsonb language sql stable as $$
  select e from jsonb_array_elements(public.get_user_graph() -> 'entities') e where e ->> 'id' = p_id;
$$;

-- The brief the next session opens with (no audio).
create function public._t_brief_of() returns jsonb language sql stable as $$
  select case when jsonb_typeof(b) = 'object' then b - 'audioBase64'::text end
  from (select public.get_session_brief() -> 'brief' as b) x;
$$;

-- Every place a forgotten NAME could be read back from, for the user:
-- stored with the user's id, no transcripts. Case-insensitive.
create function public._t_blob(p_uid uuid) returns text language sql stable security definer
set search_path = public, pg_temp as $$
  select lower(concat_ws(E'\n',
    (select string_agg(to_jsonb(e)::text, E'\n') from public.entities e where e.user_id = p_uid),
    (select string_agg(to_jsonb(r)::text, E'\n') from public.relations r where r.user_id = p_uid),
    (select string_agg(to_jsonb(f)::text, E'\n') from public.follow_ups f where f.user_id = p_uid),
    (select string_agg(to_jsonb(a)::text, E'\n') from public.asked_questions a where a.user_id = p_uid),
    (select string_agg(to_jsonb(c)::text, E'\n') from public.session_cards c where c.user_id = p_uid),
    (select string_agg(b.brief::text, E'\n') from public.session_briefs b where b.user_id = p_uid),
    (select string_agg(coalesce(n.title, '') || ' ' || coalesce(n.summary, '') || ' ' || n.mode_context::text, E'\n')
       from public.notebooks n where n.user_id = p_uid)));
$$;

create function public._t_mentions(p_blob text, p_name text) returns boolean language sql immutable as $$
  select p_blob like '%' || lower(p_name) || '%' or p_blob like '%' || replace(lower(p_name), ' ', '-') || '%';
$$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like E'\\_t\\_%' loop
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;

-- ── fixtures: two users ─────────────────────────────────────────────────────
-- U1 gets the whole chain. U2 has look-alike memory from the start.
insert into auth.users (id) values
  ('a0000000-0000-0000-0000-000000000001'),
  ('b0000000-0000-0000-0000-000000000002');

-- Embedding jobs are queued through pg_net, from config in Vault. (The queue
-- row rolls back with this transaction; nothing is sent.)
select vault.create_secret('http://127.0.0.1:9/embed-entities', 'embed_entities_url');
select vault.create_secret('scenario-test-secret', 'embed_internal_secret');

-- U2: a notebook that says "Priya Raman" and "Halvorsen Group" too, plus a
-- card, a brief, a turn and embeddings. Written through the same RPCs.
select public._t_as('b0000000-0000-0000-0000-000000000002');
set local role authenticated;
insert into public.notebooks (id, user_id, title, started_at)
  values ('b2000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'U2 one', now());
select public._t_turn('b2000000-0000-0000-0000-000000000001', 'u2-t1', 'user',
  'Priya Raman, my neighbour, was at the Halvorsen Group picnic.');
select public._t_commit('b2000000-0000-0000-0000-000000000001',
  'Priya Raman, my neighbour, was at the Halvorsen Group picnic.',
  jsonb_build_array(
    public._t_ent('priya-raman', 'Priya Raman', 'person', 'U2-PRIYA my neighbour', 4, '{}', null, '2026-11-02T10:00:00Z'),
    public._t_ent('halvorsen-group', 'Halvorsen Group', 'organization', 'U2-HALVORSEN picnic host', 3, '{}', null, '2026-11-02T10:00:00Z'),
    public._t_ent('zed-corp', 'Zed Corp', 'organization', 'U2-ONLY employer', 2, '{}', null, '2026-11-02T10:00:00Z')),
  jsonb_build_array(public._t_rel('priya-raman', 'neighbour_of', 'zed-corp', '{}', '2026-11-02T10:00:00Z')))
  as u2_commit \gset
select public._t_card('b2000000-0000-0000-0000-000000000001', 'The picnic', 'U2 met Priya Raman.',
  '[{"entityId":"priya-raman","name":"Priya Raman","note":"neighbour"}]', '["Priya Raman came to the picnic"]')
  as u2_card \gset
select public._t_brief('b2000000-0000-0000-0000-000000000001', 'Hi, how was the picnic with Priya Raman?',
  'the picnic', '["Priya Raman"]') as u2_brief \gset
reset role;
select public._t_embed('b0000000-0000-0000-0000-000000000002');

select is(:'u2_commit'::jsonb ->> 'status', 'committed', 'U2 fixture: the look-alike commit lands');
select is(:'u2_card'::jsonb ->> 'status', 'saved', 'U2 fixture: card saved');
select is(:'u2_brief'::jsonb ->> 'status', 'saved', 'U2 fixture: brief saved');

-- Isolation, asserted at every step: U2 sees only U2's memory, and U1's data
-- never shows U2's. Takes the step name so a failure says where.
create function public._t_isolation(p_step text, p_u2_pdesc text default 'U2-PRIYA my neighbour', p_u2_mentions int default 1)
returns setof text language plpgsql as $$
declare
  v_u1 constant uuid := 'a0000000-0000-0000-0000-000000000001';
  v_u2 constant uuid := 'b0000000-0000-0000-0000-000000000002';
  v_ids text[]; v_blob text; v_q text; v_n int;
begin
  -- as U2
  perform set_config('role', 'authenticated', true);
  perform public._t_as(v_u2);
  v_ids := public._t_graph_ids();
  return next is(v_ids, array['halvorsen-group', 'priya-raman', 'zed-corp'],
    p_step || ': U2 recalls exactly its own three entities');
  return next is(public._t_graph_ent('halvorsen-group') ->> 'description', 'U2-HALVORSEN picnic host',
    p_step || ': U2''s Halvorsen Group is not merged with U1''s');
  return next is((public._t_graph_ent('halvorsen-group') ->> 'mentions')::int, 3,
    p_step || ': U2''s mention count is U2''s alone');
  return next is(public._t_graph_ent('priya-raman') ->> 'description', p_u2_pdesc,
    p_step || ': U2''s Priya Raman is U2''s');
  return next is(public._t_brief_of() ->> 'openingLine', 'Hi, how was the picnic with Priya Raman?',
    p_step || ': U2 opens with U2''s brief');
  return next is((select count(*)::int from public.session_cards), 1, p_step || ': U2 sees one card');
  return next is((select count(*)::int from public.notebooks), 1, p_step || ': U2 sees one notebook');
  return next is((public.get_notebook_snapshot('a1000000-0000-0000-0000-000000000001')), null,
    p_step || ': U2 cannot read S1');
  return next is((public.get_entity_mentions('priya-raman') ->> 'total')::int, p_u2_mentions,
    p_step || ': U2''s mentions are its own');
  -- semantic seeds, service role, scoped by user id
  perform set_config('role', 'service_role', true);
  select count(*) into v_n from public.match_user_entity_embeddings(v_u2, public._t_vec('priya-raman'), 50, 'gte-small')
    where entity_id not in ('priya-raman', 'halvorsen-group', 'zed-corp');
  return next is(v_n, 0, p_step || ': U2''s embedding match returns only U2''s entities');
  perform set_config('role', 'postgres', true);
  -- stored data, by owner
  v_blob := public._t_blob(v_u2);
  return next ok(position('u2-priya' in v_blob) > 0 and position('someone' in v_blob) = 0,
    p_step || ': U2''s stored text is untouched by U1''s forgetting');
  select count(*) into v_n from public.entities where user_id = v_u2 and notebook_id <> 'b2000000-0000-0000-0000-000000000001';
  return next is(v_n, 0, p_step || ': no U2 entity sits in a U1 notebook');
  -- as U1: nothing of U2's
  perform set_config('role', 'authenticated', true);
  perform public._t_as(v_u1);
  v_ids := public._t_graph_ids();
  return next ok(not (v_ids && array['zed-corp']), p_step || ': U1 never recalls U2''s entity');
  return next ok(coalesce(public._t_graph_ent('halvorsen-group') ->> 'description', '') not like '%U2-%',
    p_step || ': U1''s Halvorsen Group carries none of U2''s text');
  return next ok(coalesce(public._t_brief_of() ->> 'openingLine', '') not like '%picnic%',
    p_step || ': U1 never opens with U2''s brief');
  return next is((select count(*)::int from public.session_cards where card::text like '%picnic%'), 0,
    p_step || ': U1 sees none of U2''s cards');
  return next is((public.get_notebook_snapshot('b2000000-0000-0000-0000-000000000001')), null,
    p_step || ': U1 cannot read U2''s notebook');
  perform set_config('role', 'postgres', true);
end $$;
grant execute on function public._t_isolation(text, text, int) to authenticated, service_role;

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 1: baseline. S1 mentions Priya Raman (sister, marathon) and Halvorsen
-- Group (employer). Commit, save a card, save a brief. S2 can recall both.
-- ════════════════════════════════════════════════════════════════════════════
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;

-- A first session on a brand-new account: nothing to recall, not returning.
select is(public._t_graph_ids(), '{}'::text[], '1 baseline: a new account recalls nothing');
select is(public.get_session_brief() -> 'returning', 'false'::jsonb, '1 baseline: a new account is not returning');
select is(public._t_brief_of(), null, '1 baseline: and has no brief');

insert into public.notebooks (id, user_id, title, started_at)
  values ('a1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'Untitled', now());
select public._t_turn('a1000000-0000-0000-0000-000000000001', 's1-t1', 'user',
  'My sister Priya Raman is training for the City Marathon. Work at Halvorsen Group has been intense.');
select public._t_turn('a1000000-0000-0000-0000-000000000001', 's1-t2', 'assistant',
  'How is Priya Raman''s training going?');

select public._t_commit('a1000000-0000-0000-0000-000000000001',
  'My sister Priya Raman is training for the City Marathon. Work at Halvorsen Group has been intense.',
  jsonb_build_array(
    public._t_ent('priya-raman', 'Priya Raman', 'person', 'My sister, training for a marathon', 1, '{}', null, '2026-11-01T10:00:00Z'),
    public._t_ent('halvorsen-group', 'Halvorsen Group', 'organization', 'Where I work', 1, '{}', null, '2026-11-01T10:00:00Z'),
    public._t_ent('city-marathon', 'City Marathon', 'event', 'Priya Raman''s first marathon', 1,
      '{"note":"trains with Priya Raman"}', '["How is Priya Raman''s training going?"]', '2026-11-01T10:00:00Z'),
    public._t_ent('work', 'work', 'concept', 'my job', 2, '{}', null, '2026-11-01T10:00:00Z')),
  jsonb_build_array(
    public._t_rel('priya-raman', 'training_for', 'city-marathon', '{"source":"Priya Raman told me"}', '2026-11-01T10:00:00Z'),
    public._t_rel('work', 'at', 'halvorsen-group', '{}', '2026-11-01T10:00:00Z')),
  '{"question":"How is Priya Raman''s training going?","reason":"the marathon","targetEntityIds":["priya-raman"]}',
  '{"question":"What does Priya Raman do?","targetEntityIds":["priya-raman"]}') as s1_commit \gset

select is(:'s1_commit'::jsonb ->> 'status', 'committed', '1 baseline: S1 commits');
select is(:'s1_commit'::jsonb ->> 'revision', '1', '1 baseline: S1 is at revision 1');

select is(:'s1_commit'::jsonb -> 'suppressedIds', null, '1 baseline: nothing was suppressed');

select public._t_card('a1000000-0000-0000-0000-000000000001', 'Priya Raman''s marathon',
  'You talked about your sister Priya Raman and Halvorsen Group.',
  '[{"entityId":"priya-raman","name":"Priya Raman","note":"Training"},{"entityId":"halvorsen-group","name":"Halvorsen Group","note":"Employer"}]',
  '["Priya Raman is training for the City Marathon","Work at Halvorsen Group is intense"]') as s1_card \gset
select is(:'s1_card'::jsonb ->> 'status', 'saved', '1 baseline: S1 card saved');

select public._t_brief('a1000000-0000-0000-0000-000000000001',
  'Welcome back. How is Priya Raman''s marathon training going?',
  'How is Priya Raman''s training going?', '["Priya Raman","City Marathon"]') as s1_brief \gset
select is(:'s1_brief'::jsonb ->> 'status', 'saved', '1 baseline: S1 brief saved');

-- The embedding job was queued by the entity insert trigger (Vault config).
reset role;
select ok(exists (select 1 from net.http_request_queue q
                  where convert_from(q.body, 'UTF8')::jsonb ->> 'notebookId' = 'a1000000-0000-0000-0000-000000000001'),
  '1 baseline: an embedding job is queued for S1');
select public._t_embed('a0000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.entity_embeddings where notebook_id = 'a1000000-0000-0000-0000-000000000001'), 4,
  '1 baseline: embed-entities wrote a row per S1 entity');

-- S2 opens. A new notebook, so its own snapshot is empty; the user-level reads carry S1.
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
insert into public.notebooks (id, user_id, title, started_at)
  values ('a1000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'Untitled', now());

select is(public._t_graph_ids(), array['city-marathon', 'halvorsen-group', 'priya-raman', 'work'],
  '1 baseline: S2 recalls S1''s entities at user level');
select is(public._t_graph_ent('priya-raman') ->> 'name', 'Priya Raman', '1 baseline: S2 recalls Priya Raman by name');
select is(public._t_graph_ent('halvorsen-group') ->> 'name', 'Halvorsen Group', '1 baseline: S2 recalls Halvorsen Group');
select is(jsonb_array_length(public.get_user_graph() -> 'relations'), 2, '1 baseline: both S1 relations are active in memory');
select is((select count(*)::int from public.user_entities where id = 'priya-raman'), 1,
  '1 baseline: user_entities has one Priya Raman');
select is((public.get_entity_mentions('priya-raman') ->> 'total')::int, 1,
  '1 baseline: S1''s words about Priya Raman are retrievable as quotes');
select is(public.get_notebook_snapshot('a1000000-0000-0000-0000-000000000002') -> 'state' -> 'entities', '{}'::jsonb,
  '1 baseline: the new notebook''s own snapshot is empty (prior memory reaches S2 through user-level reads)');
select is(public.get_session_brief() -> 'returning', 'true'::jsonb, '1 baseline: S2 is a returning session');
select is(public._t_brief_of() ->> 'openingLine', 'Welcome back. How is Priya Raman''s marathon training going?',
  '1 baseline: get_session_brief returns S1''s brief');
select is(public._t_brief_of() ->> 'sourceNotebookId', 'a1000000-0000-0000-0000-000000000001',
  '1 baseline: and says it came from S1');
select is(public._t_brief_of() -> 'playedAt', 'null'::jsonb, '1 baseline: S1''s brief is unplayed');
select is((select card ->> 'title' from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000001'),
  'Priya Raman''s marathon', '1 baseline: S1''s card is readable');

reset role;
select * from public._t_isolation('1 baseline');
-- The vector match is the retrieve-memory handler's semantic seed.
set local role service_role;
select is((select entity_id from public.match_user_entity_embeddings(
  'a0000000-0000-0000-0000-000000000001', public._t_vec('priya-raman'), 5, 'gte-small') limit 1),
  'priya-raman', '1 baseline: the semantic seed for Priya Raman finds her');
select is((select count(*)::int from public.match_user_entity_embeddings(
  'a0000000-0000-0000-0000-000000000001', public._t_vec('halvorsen-group'), 50, 'gte-small')), 4,
  '1 baseline: the match covers all four of U1''s entities, and only U1''s');
reset role;

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 2: continuity. S2 adds a fact about Priya, Priya Nair (a colleague), a
-- Lisbon trip (S2 only), and mentions Halvorsen Group again.
-- ════════════════════════════════════════════════════════════════════════════
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public._t_turn('a1000000-0000-0000-0000-000000000002', 's2-t1', 'user',
  'Priya Raman has a stress fracture and may skip the marathon. Priya Nair at Halvorsen Group is planning a Lisbon trip.');

select public._t_commit('a1000000-0000-0000-0000-000000000002',
  'Priya Raman has a stress fracture and may skip the marathon. Priya Nair at Halvorsen Group is planning a Lisbon trip.',
  jsonb_build_array(
    public._t_ent('priya-raman', 'Priya Raman', 'person', 'My sister. Stress fracture, may skip the marathon', 1, '{}', null, '2026-11-03T10:00:00Z'),
    public._t_ent('halvorsen-group', 'Halvorsen Group', 'organization', 'Where I work; deadlines every week', 1, '{}', null, '2026-11-03T10:00:00Z'),
    public._t_ent('priya-nair', 'Priya Nair', 'person', 'Colleague at Halvorsen Group', 1, '{}', null, '2026-11-03T10:00:00Z'),
    public._t_ent('lisbon-trip', 'Lisbon trip', 'event', 'A trip Priya Nair is planning', 1, '{}', null, '2026-11-03T10:00:00Z')),
  jsonb_build_array(
    public._t_rel('priya-nair', 'works_at', 'halvorsen-group', '{}', '2026-11-03T10:00:00Z'),
    public._t_rel('priya-nair', 'planning', 'lisbon-trip', '{}', '2026-11-03T10:00:00Z')),
  '{"question":"Did Priya Raman recover from the fracture?","reason":"injury","targetEntityIds":["city-marathon"]}',
  null) as s2_commit \gset
select is(:'s2_commit'::jsonb ->> 'status', 'committed', '2 continuity: S2 commits');

select public._t_card('a1000000-0000-0000-0000-000000000002', 'The fracture',
  'Priya Raman has a stress fracture. Priya Nair is going to Lisbon.',
  '[{"entityId":"priya-raman","name":"Priya Raman","note":"Injured"},{"entityId":"priya-nair","name":"Priya Nair","note":"Colleague"}]',
  '["Priya Raman may skip the marathon","Priya Nair plans a Lisbon trip"]') as s2_card \gset
select public._t_brief('a1000000-0000-0000-0000-000000000002',
  'Hi again. How is Priya Raman''s leg?', 'Priya Raman''s stress fracture', '["Priya Raman","Halvorsen Group"]') as s2_brief \gset
select is(:'s2_brief'::jsonb ->> 'status', 'saved', '2 continuity: S2''s brief is saved');

reset role;
select ok(exists (select 1 from net.http_request_queue q
                  where convert_from(q.body, 'UTF8')::jsonb ->> 'notebookId' = 'a1000000-0000-0000-0000-000000000002'),
  '2 continuity: an embedding job is queued for S2');
select public._t_embed('a0000000-0000-0000-0000-000000000001');
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;

select is(public._t_graph_ids(),
  array['city-marathon', 'halvorsen-group', 'lisbon-trip', 'priya-nair', 'priya-raman', 'work'],
  '2 continuity: recall reflects both sessions');
select is((select count(*)::int from public.user_entities where id = 'priya-raman'), 1,
  '2 continuity: no duplicate Priya Raman');
select is((select count(*)::int from public.user_entities where id = 'halvorsen-group'), 1,
  '2 continuity: no duplicate Halvorsen Group');
select is(jsonb_array_length(public.get_user_graph() -> 'entities'), 6, '2 continuity: six distinct entities');
select is((public.get_user_graph() ->> 'entityCount')::int, 6, '2 continuity: entityCount agrees');
select is((public._t_graph_ent('priya-raman') ->> 'notebookCount')::int, 2, '2 continuity: Priya Raman is backed by both sessions');
select is((public._t_graph_ent('priya-raman') ->> 'mentions')::int, 2, '2 continuity: her mentions add up across sessions');
select is(public._t_graph_ent('priya-raman') ->> 'description', 'My sister. Stress fracture, may skip the marathon',
  '2 continuity: the newer session''s fact about Priya wins');
select is((public._t_graph_ent('halvorsen-group') ->> 'mentions')::int, 2, '2 continuity: Halvorsen Group mentions add up');
select is((select count(*)::int from public.entities where user_id = 'a0000000-0000-0000-0000-000000000001' and id = 'priya-raman'), 2,
  '2 continuity: stored per notebook, merged on read');
select is((public.get_entity_mentions('priya-raman') ->> 'total')::int, 2,
  '2 continuity: quotes from both sessions are retrievable');
select is(jsonb_array_length(public.get_user_graph() -> 'relations'), 4, '2 continuity: relations from both sessions are active');
select is(public._t_brief_of() ->> 'openingLine', 'Hi again. How is Priya Raman''s leg?', '2 continuity: S2''s brief replaces S1''s');
select is(public._t_brief_of() ->> 'sourceNotebookId', 'a1000000-0000-0000-0000-000000000002', '2 continuity: and is from S2');
select is((select count(*)::int from public.session_cards), 2, '2 continuity: two cards, one per session');
select is((select count(*)::int from public.session_briefs), 1, '2 continuity: still one brief row');

reset role;
select * from public._t_isolation('2 continuity');
reset role;

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 3: off the record. S3 opens (the brief plays), nothing commits, and
-- delete_empty_notebook runs at leave. Memory is exactly as before.
-- ════════════════════════════════════════════════════════════════════════════
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
create temp table _before_s3 as
  select
    (select count(*) from public.entities where user_id = 'a0000000-0000-0000-0000-000000000001') as entities,
    (select count(*) from public.relations where user_id = 'a0000000-0000-0000-0000-000000000001') as relations,
    (select count(*) from public.journal_entries where user_id = 'a0000000-0000-0000-0000-000000000001') as entries,
    (select count(*) from public.follow_ups where user_id = 'a0000000-0000-0000-0000-000000000001') as follow_ups,
    (select count(*) from public.asked_questions where user_id = 'a0000000-0000-0000-0000-000000000001') as asked,
    (select count(*) from public.conversation_turns where user_id = 'a0000000-0000-0000-0000-000000000001') as turns,
    (select count(*) from public.session_cards where user_id = 'a0000000-0000-0000-0000-000000000001') as cards,
    (select count(*) from public.notebooks where user_id = 'a0000000-0000-0000-0000-000000000001') as notebooks,
    public.get_user_graph() as graph,
    public._t_brief_of() as brief;
grant select on _before_s3 to authenticated;

insert into public.notebooks (id, user_id, title, started_at)
  values ('a1000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'Untitled', now());
-- The opening plays S2's brief: mark_session_brief_played is the one write an
-- off-the-record session makes (ruled metadata). Retrieval counts a call.
select public.mark_session_brief_played((public.get_session_brief() -> 'brief' ->> 'createdAt')::timestamptz);
select is(public.bump_retrieve_rate('a1000000-0000-0000-0000-000000000003'), true, '3 off the record: a retrieval call is counted');
select is(public._t_graph_ids(), array['city-marathon', 'halvorsen-group', 'lisbon-trip', 'priya-nair', 'priya-raman', 'work'],
  '3 off the record: S3 still recalls S1 and S2 while it is open');
select is(public.delete_empty_notebook('a1000000-0000-0000-0000-000000000003'), '{"deleted": true}'::jsonb,
  '3 off the record: leaving deletes the empty notebook');

select is((select count(*) from public.entities where user_id = 'a0000000-0000-0000-0000-000000000001'), (select entities from _before_s3), '3 off the record: entity count unchanged');
select is((select count(*) from public.relations where user_id = 'a0000000-0000-0000-0000-000000000001'), (select relations from _before_s3), '3 off the record: relation count unchanged');
select is((select count(*) from public.journal_entries where user_id = 'a0000000-0000-0000-0000-000000000001'), (select entries from _before_s3), '3 off the record: entry count unchanged');
select is((select count(*) from public.follow_ups where user_id = 'a0000000-0000-0000-0000-000000000001'), (select follow_ups from _before_s3), '3 off the record: follow-up count unchanged');
select is((select count(*) from public.asked_questions where user_id = 'a0000000-0000-0000-0000-000000000001'), (select asked from _before_s3), '3 off the record: asked-question count unchanged');
select is((select count(*) from public.conversation_turns where user_id = 'a0000000-0000-0000-0000-000000000001'), (select turns from _before_s3), '3 off the record: turn count unchanged');
select is((select count(*) from public.session_cards where user_id = 'a0000000-0000-0000-0000-000000000001'), (select cards from _before_s3), '3 off the record: card count unchanged');
select is((select count(*) from public.notebooks where user_id = 'a0000000-0000-0000-0000-000000000001'), (select notebooks from _before_s3), '3 off the record: no notebook is left behind');
select is(public.get_user_graph(), (select graph from _before_s3), '3 off the record: the whole user graph is identical');
select is(public._t_brief_of() - 'playedAt', (select brief - 'playedAt' from _before_s3), '3 off the record: the brief is unchanged, apart from being marked played');
select isnt(public._t_brief_of() -> 'playedAt', 'null'::jsonb, '3 off the record: playing the opening marks the brief played (ruled metadata)');
select is((select count(*)::int from public.session_briefs), 1, '3 off the record: still one brief');
reset role;
select is((select count(*)::int from public.retrieve_rate_limits where scope = 'notebook:a1000000-0000-0000-0000-000000000003'), 0,
  '3 off the record: its retrieval counter is gone with it');
select is((select count(*)::int from public.entity_embeddings where user_id = 'a0000000-0000-0000-0000-000000000001'), 8,
  '3 off the record: embeddings unchanged');
select * from public._t_isolation('3 off the record');

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 4: auto-forget. Retention 7 days, S1's turns and entries 8 days old.
-- ════════════════════════════════════════════════════════════════════════════
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(public.set_transcript_retention(7), 7, '4 auto-forget: retention is set to 7 days');
reset role;
update public.conversation_turns set created_at = now() - interval '8 days'
  where notebook_id = 'a1000000-0000-0000-0000-000000000001';
update public.journal_entries set created_at = now() - interval '8 days'
  where notebook_id = 'a1000000-0000-0000-0000-000000000001';
-- U2 never set a retention; an ancient turn of theirs must stay.
update public.conversation_turns set created_at = now() - interval '400 days'
  where notebook_id = 'b2000000-0000-0000-0000-000000000001';

create temp table _before_sweep as
  select (select revision from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001') as s1_rev,
         (select updated_at from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001') as s1_updated,
         (select card from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000001') as s1_card,
         (select source_revision from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000001') as s1_card_rev;

select is(public.forget_old_transcripts() ->> 'turns', '2', '4 auto-forget: the sweep removes S1''s two turns');

select is((select count(*)::int from public.conversation_turns where notebook_id = 'a1000000-0000-0000-0000-000000000001'), 0, '4 auto-forget: S1''s transcript is gone');
select is((select count(*)::int from public.journal_entries where notebook_id = 'a1000000-0000-0000-0000-000000000001'), 0, '4 auto-forget: S1''s journal entries are gone');
select is((select count(*)::int from public.conversation_turns where notebook_id = 'a1000000-0000-0000-0000-000000000002'), 1, '4 auto-forget: S2 is newer than 7 days and stays');
select is((select count(*)::int from public.journal_entries where notebook_id = 'a1000000-0000-0000-0000-000000000002'), 1, '4 auto-forget: S2''s entry stays');
select is((select count(*)::int from public.conversation_turns where notebook_id = 'b2000000-0000-0000-0000-000000000001'), 1, '4 auto-forget: U2 (keep forever) loses nothing, however old');
select isnt((select transcript_forgotten_at from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001'), null,
  '4 auto-forget: S1 is marked transcript_forgotten_at');
select is((select transcript_forgotten_at from public.notebooks where id = 'a1000000-0000-0000-0000-000000000002'), null,
  '4 auto-forget: S2 is not marked');
select is((select revision from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001'), (select s1_rev from _before_sweep),
  '4 auto-forget: the sweep leaves S1''s revision alone');
select is((select source_revision from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000001'),
  (select revision from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001'),
  '4 auto-forget: S1''s card is current, so nothing asks for a new one');
select is((select card from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000001'),
  (select s1_card from _before_sweep), '4 auto-forget: S1''s card is untouched');

select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(public._t_graph_ids(), array['city-marathon', 'halvorsen-group', 'lisbon-trip', 'priya-nair', 'priya-raman', 'work'],
  '4 auto-forget: entities still recall');
select is(public._t_graph_ent('priya-raman') ->> 'name', 'Priya Raman', '4 auto-forget: Priya Raman is still recalled by name');
select is(public._t_graph_ent('priya-raman') ->> 'description', 'My sister. Stress fracture, may skip the marathon', '4 auto-forget: and by what was said');
select is(jsonb_array_length(public.get_user_graph() -> 'relations'), 4, '4 auto-forget: relations still recall');
select is((select card ->> 'title' from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000001'), 'Priya Raman''s marathon',
  '4 auto-forget: S1''s card still names Priya');
select is(public._t_brief_of() ->> 'openingLine', 'Hi again. How is Priya Raman''s leg?', '4 auto-forget: the brief still opens with Priya');
select is((public.get_session_brief() -> 'returning'), 'true'::jsonb, '4 auto-forget: still a returning account with no transcript left in S1');
select is((public.get_entity_mentions('priya-raman') ->> 'total')::int, 1, '4 auto-forget: quotes come only from what is still held (S2)');
select is(jsonb_array_length(public.get_notebook_snapshot('a1000000-0000-0000-0000-000000000001') -> 'state' -> 'followUps'), 1,
  '4 auto-forget: S1''s follow-up is still there for Lumen to ask');
select is(jsonb_array_length(public.get_notebook_snapshot('a1000000-0000-0000-0000-000000000001') -> 'state' -> 'entries'), 0,
  '4 auto-forget: S1 reopens with no entries, only its graph');
select is(public.delete_empty_notebook('a1000000-0000-0000-0000-000000000001'), '{"deleted": false}'::jsonb,
  '4 auto-forget: an off-the-record visit to S1 does not delete it');
select is((select count(*)::int from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001'), 1, '4 auto-forget: S1 still exists');

-- S1 reopened and continued after the sweep (undone right after): the card goes
-- behind the notebook, and the marker is what stops close-session writing a
-- new card from the one turn that survives.
reset role;
savepoint continue_s1;
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is((public._t_commit('a1000000-0000-0000-0000-000000000001', 'Priya Raman ran 10k today.',
  jsonb_build_array(public._t_ent('priya-raman', 'Priya Raman', 'person', 'My sister. Ran 10k', 1, '{}', null, '2026-11-04T10:00:00Z')),
  '[]') ->> 'revision'), '2', '4 auto-forget: S1 can be continued after its transcript went');
select isnt((select transcript_forgotten_at from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001'), null,
  '4 auto-forget: and keeps its marker, so the card is not rewritten from the surviving turn');
select ok((select source_revision from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000001') <
          (select revision from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001'),
  '4 auto-forget: the card is now behind the notebook (so only the marker prevents a rewrite)');
reset role;
rollback to savepoint continue_s1;
select * from public._t_isolation('4 auto-forget');

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 5a: remove a concept ("work"). It leaves recall, stays a removal: its
-- word is not redacted anywhere, before or after a later Forget.
-- ════════════════════════════════════════════════════════════════════════════
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(public.remove_entity('work'), '{"removedFrom": 1}'::jsonb, '5a remove: "work" is removed from its one notebook');
select ok(not (public._t_graph_ids() @> array['work']), '5a remove: "work" is no longer recalled');
select is(public._t_graph_ids(), array['city-marathon', 'halvorsen-group', 'lisbon-trip', 'priya-nair', 'priya-raman'],
  '5a remove: everything else is still recalled');
select is(jsonb_array_length(public.get_user_graph() -> 'relations'), 3, '5a remove: its relation went with it');
select is(public.redact_forgotten_text('Work was fine, back to work. Work talk.'), 'Work was fine, back to work. Work talk.',
  '5a remove: the word "work" is not redacted in text');
reset role;
select todo_start('BUG-3: Remove bumps the notebook revision, so a card that does not mention the entity goes stale (Forget fixed this in R6, Remove did not)');
select is((select source_revision from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000001'),
          (select revision from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001'),
  '5a remove: S1''s card, which does not mention "work" the entity, is still current');
select todo_end();
select is((select count(*)::int from public.entity_embeddings where entity_id = 'work'), 0, '5a remove: its embedding is gone');
select is((select array_agg(kind order by kind) from public.entity_suppressions
           where user_id = 'a0000000-0000-0000-0000-000000000001'), array['removed'], '5a remove: stored as a removal, not a forget');
select * from public._t_isolation('5a remove');

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 5b: forget Priya Raman. Everything that names her goes, in every
-- notebook. Priya Nair, a different person, stays whole.
-- ════════════════════════════════════════════════════════════════════════════
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(public.forget_entity_preview('priya-raman') -> 'briefDeleted', 'true'::jsonb, '5b forget: the preview says the brief goes');
select is(public.forget_entity('priya-raman') ->> 'notebooks', '2', '5b forget: she was in two notebooks');
reset role;

select ok(not public._t_mentions(public._t_blob('a0000000-0000-0000-0000-000000000001'), 'Priya Raman'),
  '5b forget: no stored entity, relation, follow-up, question, card, brief or title names her');
select is((select count(*)::int from public.entities where user_id = 'a0000000-0000-0000-0000-000000000001' and id = 'priya-raman'), 0,
  '5b forget: her entity is gone from every notebook');
select is((select count(*)::int from public.relations where user_id = 'a0000000-0000-0000-0000-000000000001'
           and 'priya-raman' in (source_id, target_id)), 0, '5b forget: and her relations');
select is((select count(*)::int from public.follow_ups where user_id = 'a0000000-0000-0000-0000-000000000001'), 0,
  '5b forget: no follow-up is left to ask: the one aimed at her and the one that only names her');
select is((select count(*)::int from public.asked_questions where user_id = 'a0000000-0000-0000-0000-000000000001'), 0,
  '5b forget: no asked question is left');
select is((select count(*)::int from public.entity_embeddings where user_id = 'a0000000-0000-0000-0000-000000000001' and entity_id = 'priya-raman'), 0,
  '5b forget: her embeddings are gone');
select is((select count(*)::int from public.entity_embeddings where user_id = 'a0000000-0000-0000-0000-000000000001' and entity_id = 'city-marathon'), 0,
  '5b forget: so is the stale embedding of an entity whose text named her');
select ok((select to_jsonb(e)::text from public.entities e where e.id = 'city-marathon') not ilike '%raman%',
  '5b forget: that entity''s description, metadata and questions no longer name her');
select is((select description from public.entities where id = 'city-marathon' and user_id = 'a0000000-0000-0000-0000-000000000001'),
  'someone''s first marathon', '5b forget: her name became "someone"');
select is((select title from public.notebooks where id = 'a1000000-0000-0000-0000-000000000001'), 'someone''s marathon',
  '5b forget: S1''s title is redacted');
select ok(position('someone' in (select card::text from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000001')) > 0,
  '5b forget: S1''s card says "someone"');
select ok(not exists (select 1 from public.session_cards c, jsonb_array_elements(c.card -> 'remember') r
                      where c.user_id = 'a0000000-0000-0000-0000-000000000001' and r ->> 'entityId' = 'priya-raman'),
  '5b forget: no card points at her any more');
-- Over-redaction guard: Priya Nair is a different person.
select is((select description from public.entities where id = 'priya-nair'), 'Colleague at Halvorsen Group', '5b forget: Priya Nair is untouched');
select is((select description from public.entities where id = 'lisbon-trip'), 'A trip Priya Nair is planning',
  '5b forget: text that names Priya Nair is untouched');
select is((select name from public.entities where id = 'priya-nair'), 'Priya Nair', '5b forget: Priya Nair keeps her name');
select ok((select card ->> 'summary' from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000002') like '%Priya Nair is going to Lisbon.',
  '5b forget: S2''s card keeps the sentence about Priya Nair');
select is((select card ->> 'summary' from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000002'),
  'someone has a stress fracture. Priya Nair is going to Lisbon.', '5b forget: and redacts only the sentence about Priya Raman');
select ok(exists (select 1 from public.session_cards c, jsonb_array_elements(c.card -> 'remember') r
                  where c.notebook_id = 'a1000000-0000-0000-0000-000000000002' and r ->> 'entityId' = 'priya-nair'),
  '5b forget: S2''s card still points at Priya Nair');
select is((select count(*)::int from public.relations where id = 'priya-nair__works_at__halvorsen-group'), 1, '5b forget: Priya Nair''s relations stay');
select is((select count(*)::int from public.entity_embeddings where user_id = 'a0000000-0000-0000-0000-000000000001'
           and entity_id in ('priya-nair', 'halvorsen-group', 'lisbon-trip')), 4,
  '5b forget: embeddings of entities that never named her stay (Priya Nair, Lisbon trip, Halvorsen Group in two notebooks)');
select is(public.redact_forgotten_text('Priya Nair met Priya Raman, then Priya Ramanathan and Priyanka.'),
  'Priya Nair met someone, then Priya Ramanathan and Priyanka.', '5b forget: the matcher takes whole names only');
select is(public.redact_forgotten_text('Priya Nair''s lisbon trip'), 'Priya Nair''s lisbon trip', '5b forget: a possessive of the other Priya is whole');

select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(public._t_graph_ids(), array['city-marathon', 'halvorsen-group', 'lisbon-trip', 'priya-nair'],
  '5b forget: the next session recalls everyone but her (and not "work")');
select is(public._t_graph_ent('priya-nair') ->> 'description', 'Colleague at Halvorsen Group', '5b forget: Priya Nair is recalled normally');
select is(jsonb_array_length(public.get_user_graph() -> 'relations'), 2, '5b forget: only the relations that do not touch her remain');
select is((select count(*)::int from public.user_entities where id = 'priya-raman'), 0, '5b forget: user_entities has no Priya Raman');
select is(public._t_brief_of(), null, '5b forget: the brief that named her is deleted');
select is(public.get_session_brief() -> 'returning', 'true'::jsonb, '5b forget: the account is still returning');
select is(public._t_brief('a1000000-0000-0000-0000-000000000002', 'Hi again. How is Priya Raman''s leg?', 'x', '["Priya Raman"]') ->> 'status',
  'unchanged', '5b forget: a new brief naming her is refused');
select is(public._t_brief('a1000000-0000-0000-0000-000000000002', 'How is PRIYA RAMAN doing?', 'x', '[]') ->> 'status',
  'unchanged', '5b forget: in any casing');
select is(public._t_brief('a1000000-0000-0000-0000-000000000002', 'Hi.', 'How is Priya Raman''s training?', '[]') ->> 'status',
  'unchanged', '5b forget: and in the thread or focus');
select is(public._t_brief_of(), null, '5b forget: so there is still no brief');
select is(public._t_brief('a1000000-0000-0000-0000-000000000002', 'Hi. How is Priya Nair''s Lisbon trip?', 'the trip', '["Priya Nair"]') ->> 'status',
  'saved', '5b forget: a brief about Priya Nair is saved');
select is(public._t_brief_of() ->> 'openingLine', 'Hi. How is Priya Nair''s Lisbon trip?', '5b forget: and opens the next session');

-- S5: a scratch session after the forget, for two more paths (deleted right after):
-- a card DRAFT written while the conversation goes on, and an entity whose
-- name merely contains hers.
insert into public.notebooks (id, user_id, title, started_at)
  values ('a1000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001', 'Untitled', now());
select public._t_commit('a1000000-0000-0000-0000-000000000005', 'Priya Raman Foundation held a race.',
  jsonb_build_array(public._t_ent('priya-raman-foundation', 'Priya Raman Foundation', 'organization', 'Runs a race', 1, '{}', null, '2026-11-06T09:00:00Z')),
  '[]') as s5_commit \gset
select public.save_session_card('a1000000-0000-0000-0000-000000000005', 1, jsonb_build_object(
  'version', 1, 'notebookId', 'a1000000-0000-0000-0000-000000000005', 'conversationMode', 'just_talk', 'sourceRevision', 1,
  'generatedAt', '2026-11-06T12:00:00Z', 'title', 'Race day', 'summary', 'Priya Raman ran.',
  'remember', '[]'::jsonb, 'notes', '["Priya Raman won"]'::jsonb), 'Race day', 'Priya Raman ran.', true) as s5_draft \gset
select is(:'s5_draft'::jsonb ->> 'status', 'saved', '5b forget: a card draft is saved');
select is((select card -> 'notes' from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000005'), '["someone won"]'::jsonb,
  '5b forget: and redacted like a final card');
select is((select card ->> 'summary' from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000005'), 'someone ran.',
  '5b forget: summary too');
select is((select name from public.entities where id = 'priya-raman-foundation'), 'someone Foundation',
  '5b forget: an entity that merely contains her name is renamed');
select todo_start('BUG-4: the id of that entity still spells her name and is returned by user-level recall');
select ok(not (public.get_user_graph()::text ilike '%priya-raman%'), '5b forget: no recalled entity id spells her name');
select todo_end();
reset role;
delete from public.notebooks where id = 'a1000000-0000-0000-0000-000000000005';
select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;

-- S4: the next session, after the forget. The user mentions her again.
insert into public.notebooks (id, user_id, title, started_at)
  values ('a1000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001', 'Untitled', now());
select public._t_commit('a1000000-0000-0000-0000-000000000004',
  'Priya Raman called again. Work at Halvorsen Group is better; back to work.',
  jsonb_build_array(
    public._t_ent('priya-raman', 'Priya Raman', 'person', 'Called again', 1, '{}', null, '2026-11-06T10:00:00Z'),
    public._t_ent('halvorsen-group', 'Halvorsen Group', 'organization', 'Where I work. Priya Raman visited. Work is better', 1,
      '{"visitor":"Priya Raman"}', '["How did Priya Raman like Halvorsen Group?"]', '2026-11-06T10:00:00Z'),
    public._t_ent('work', 'work', 'concept', 'my job', 1, '{}', null, '2026-11-06T10:00:00Z'),
    public._t_ent('work-project', 'Work project', 'concept', 'Work stuff: back to work', 1, '{}', null, '2026-11-06T10:00:00Z')),
  jsonb_build_array(
    public._t_rel('priya-raman', 'visited', 'halvorsen-group', '{}', '2026-11-06T10:00:00Z'),
    public._t_rel('work-project', 'at', 'halvorsen-group', '{"who":"Priya Raman"}', '2026-11-06T10:00:00Z')),
  '{"question":"How is Priya Raman doing?","reason":"she called","targetEntityIds":[]}',
  '{"question":"How is work going?","targetEntityIds":["work"]}') as s4_commit \gset
select is(:'s4_commit'::jsonb ->> 'status', 'committed', '5b forget: a later commit that mentions her still lands');
select is((select array_agg(x order by x) from jsonb_array_elements_text(:'s4_commit'::jsonb -> 'suppressedIds') x),
  array['priya-raman', 'work'], '5b forget: and reports the two ids it dropped');
select ok(not (public._t_graph_ids() @> array['priya-raman']), '5b forget: she is not recreated');
select ok(not (public._t_graph_ids() @> array['work']), '5b forget: nor is the removed concept');
select ok(public._t_graph_ids() @> array['work-project'], '5b forget: but a different entity with "work" in its name is recalled');
reset role;
select is((select count(*)::int from public.entities where user_id = 'a0000000-0000-0000-0000-000000000001' and id in ('priya-raman', 'work')), 0,
  '5b forget: neither is stored');
select is((select description from public.entities where notebook_id = 'a1000000-0000-0000-0000-000000000004' and id = 'halvorsen-group'),
  'Where I work. someone visited. Work is better', '5b forget: another entity''s text is redacted on the way in, "work" is not');
select is((select metadata from public.entities where notebook_id = 'a1000000-0000-0000-0000-000000000004' and id = 'halvorsen-group'),
  '{"visitor": "someone"}'::jsonb, '5b forget: and its metadata');
select is((select questions from public.entities where notebook_id = 'a1000000-0000-0000-0000-000000000004' and id = 'halvorsen-group'),
  array['How did someone like Halvorsen Group?'], '5b forget: and its questions');
select is((select description from public.entities where notebook_id = 'a1000000-0000-0000-0000-000000000004' and id = 'work-project'),
  'Work stuff: back to work', '5b forget: "work" in other text is unchanged');
select is((select count(*)::int from public.relations where notebook_id = 'a1000000-0000-0000-0000-000000000004'), 1,
  '5b forget: the relation that touched her was dropped');
select is((select metadata from public.relations where notebook_id = 'a1000000-0000-0000-0000-000000000004'),
  '{"who": "someone"}'::jsonb, '5b forget: the other relation''s metadata is redacted');
select is((select count(*)::int from public.follow_ups where notebook_id = 'a1000000-0000-0000-0000-000000000004'), 0,
  '5b forget: a follow-up that names her is not stored');
select is((select count(*)::int from public.asked_questions where notebook_id = 'a1000000-0000-0000-0000-000000000004'), 1,
  '5b forget: an unrelated asked question is');
select is((select target_entity_ids from public.asked_questions where notebook_id = 'a1000000-0000-0000-0000-000000000004'), '{}'::text[],
  '5b forget: without the removed concept as a target');
select ok(not public._t_mentions(public._t_blob('a0000000-0000-0000-0000-000000000001'), 'Priya Raman'),
  '5b forget: still nothing stored names her after S4');

select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
-- S4's card and brief, written the way close-session would.
select public._t_card('a1000000-0000-0000-0000-000000000004', 'Work and Halvorsen Group',
  'Back to work was fine. Priya Raman called.', '[{"entityId":"halvorsen-group","name":"Halvorsen Group","note":"Employer"}]',
  '["Back to work was fine","Priya Raman called","Priya Nair is still planning Lisbon"]') as s4_card \gset
select is((select card ->> 'title' from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000004'), 'Work and Halvorsen Group',
  '5b forget: a later card keeps the word "work"');
select is((select card -> 'notes' from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000004'),
  '["Back to work was fine", "someone called", "Priya Nair is still planning Lisbon"]'::jsonb,
  '5b forget: and redacts only her');
select is((select title from public.notebooks where id = 'a1000000-0000-0000-0000-000000000004'), 'Work and Halvorsen Group', '5b forget: S4''s title is its card''s');
select is(public._t_brief('a1000000-0000-0000-0000-000000000004', 'Hi. How is work at Halvorsen Group?', 'work at Halvorsen Group', '["work"]') ->> 'status',
  'saved', '5b forget: a brief with the removed word "work" is saved');
select is(public._t_brief_of() ->> 'openingLine', 'Hi. How is work at Halvorsen Group?', '5b forget: and not redacted');

-- The transcript and quotes still hold her name (R10): a gap, shown here.
select todo_start('BUG-2: quotes and snapshot entries still return the forgotten name (journal_entries.text is not redacted)');
select ok(not exists (
    select 1 from jsonb_array_elements(public.get_entity_mentions('halvorsen-group') -> 'mentions') m
    where m ->> 'excerpt' ilike '%priya raman%'),
  '5b forget: retrieval quotes for a surviving entity do not repeat her name');
select ok(not exists (
    select 1 from jsonb_array_elements(public.get_notebook_snapshot('a1000000-0000-0000-0000-000000000002') -> 'state' -> 'entries') e
    where e ->> 'text' ilike '%priya raman%'),
  '5b forget: a reopened notebook''s entries (resume context) do not repeat her name');
select todo_end();

reset role;
select * from public._t_isolation('5 remove and forget');

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 6: delete S2. What only S2 backed goes; what S1 and S4 back stays; the
-- current brief goes (it can carry a deleted session's words).
-- ════════════════════════════════════════════════════════════════════════════
select public._t_as('a0000000-0000-0000-0000-000000000001');
reset role;
select public._t_embed('a0000000-0000-0000-0000-000000000001');
select public._t_as('b0000000-0000-0000-0000-000000000002');
set local role authenticated;
select is(public.delete_notebook('a1000000-0000-0000-0000-000000000002'), '{"deleted": false}'::jsonb, '6 delete: U2 cannot delete U1''s S2');
reset role;
select is((select count(*)::int from public.notebooks where id = 'a1000000-0000-0000-0000-000000000002'), 1, '6 delete: so S2 is still there');

select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(public._t_brief_of() ->> 'sourceNotebookId', 'a1000000-0000-0000-0000-000000000004', '6 delete: the current brief is S4''s, not S2''s');
select is(public._t_graph_ids(), array['city-marathon', 'halvorsen-group', 'lisbon-trip', 'priya-nair', 'work-project'], '6 delete: before: memory from S1, S2 and S4');
select is(public.delete_notebook('a1000000-0000-0000-0000-000000000002'), '{"deleted": true}'::jsonb, '6 delete: the owner deletes S2');
select is(public.delete_notebook('a1000000-0000-0000-0000-000000000002'), '{"deleted": false}'::jsonb, '6 delete: a second delete is a no-op');
reset role;
select is((select sum(n)::int from (
    select count(*) n from public.entities where notebook_id = 'a1000000-0000-0000-0000-000000000002'
    union all select count(*) from public.relations where notebook_id = 'a1000000-0000-0000-0000-000000000002'
    union all select count(*) from public.journal_entries where notebook_id = 'a1000000-0000-0000-0000-000000000002'
    union all select count(*) from public.follow_ups where notebook_id = 'a1000000-0000-0000-0000-000000000002'
    union all select count(*) from public.asked_questions where notebook_id = 'a1000000-0000-0000-0000-000000000002'
    union all select count(*) from public.conversation_turns where notebook_id = 'a1000000-0000-0000-0000-000000000002'
    union all select count(*) from public.session_cards where notebook_id = 'a1000000-0000-0000-0000-000000000002'
    union all select count(*) from public.entity_embeddings where notebook_id = 'a1000000-0000-0000-0000-000000000002'
    union all select count(*) from public.notebook_commit_requests where notebook_id = 'a1000000-0000-0000-0000-000000000002'
    union all select count(*) from public.notebooks where id = 'a1000000-0000-0000-0000-000000000002') x), 0,
  '6 delete: nothing of S2 is left in any table');

select public._t_as('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(public._t_graph_ids(), array['city-marathon', 'halvorsen-group', 'work-project'],
  '6 delete: what only S2 backed (Priya Nair, the Lisbon trip) is gone from recall');
select is(jsonb_array_length(public.get_user_graph() -> 'relations'), 1, '6 delete: and S2''s relations');
select ok(public._t_graph_ent('halvorsen-group') is not null, '6 delete: Halvorsen Group is still recalled');
select is((public._t_graph_ent('halvorsen-group') ->> 'notebookCount')::int, 2, '6 delete: backed by S1 and S4 now');
select is((public._t_graph_ent('halvorsen-group') ->> 'mentions')::int, 2, '6 delete: with S2''s mention taken off');
select is((select description from public.entities where notebook_id = 'a1000000-0000-0000-0000-000000000001' and id = 'halvorsen-group'),
  'Where I work', '6 delete: S1''s own Halvorsen Group is intact');
select is((select notebook_ids @> array['a1000000-0000-0000-0000-000000000001'::uuid] from public.user_entities where id = 'halvorsen-group'),
  true, '6 delete: user memory still shows S1 as a source');
select is(public._t_brief_of(), null, '6 delete: the current brief is deleted');
select is(public.get_session_brief() -> 'returning', 'true'::jsonb, '6 delete: the account is still returning');
select is((select count(*)::int from public.session_cards), 2, '6 delete: S1''s and S4''s cards remain');
select is(public.redact_forgotten_text('Priya Raman called'), 'someone called', '6 delete: Priya Raman is still forgotten');
select is(public._t_graph_ent('priya-nair'), null, '6 delete: and Priya Nair, whom only S2 knew, is not kept anywhere');
reset role;
select ok(not public._t_mentions(public._t_blob('a0000000-0000-0000-0000-000000000001'), 'Priya Raman'),
  '6 delete: still nothing stored names Priya Raman');
set local role service_role;
select is((select entity_id from public.match_user_entity_embeddings(
  'a0000000-0000-0000-0000-000000000001', public._t_vec('halvorsen-group'), 5, 'gte-small') limit 1),
  'halvorsen-group', '6 delete: the semantic seed for Halvorsen Group still finds it');
select is((select count(*)::int from public.match_user_entity_embeddings(
  'a0000000-0000-0000-0000-000000000001', public._t_vec('priya-nair'), 50, 'gte-small')
  where entity_id in ('priya-nair', 'lisbon-trip', 'priya-raman', 'work')), 0,
  '6 delete: no seed finds Priya Nair, the Lisbon trip, Priya Raman or "work"');
reset role;

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 7: isolation, once more at the end. U2 mentions Priya Raman again: U1's
-- forget does not touch U2's, and U2's commit is not suppressed.
-- ════════════════════════════════════════════════════════════════════════════
select public._t_as('b0000000-0000-0000-0000-000000000002');
set local role authenticated;
select public._t_commit('b2000000-0000-0000-0000-000000000001', 'Priya Raman brought cake to Halvorsen Group.',
  jsonb_build_array(public._t_ent('priya-raman', 'Priya Raman', 'person', 'U2-PRIYA brought cake', 5, '{}', null, '2026-11-06T10:00:00Z')),
  '[]') as u2_commit2 \gset
select is(:'u2_commit2'::jsonb ->> 'status', 'committed', '7 isolation: U2 can still mention Priya Raman after U1 forgot her');
select is(:'u2_commit2'::jsonb -> 'suppressedIds', null, '7 isolation: and nothing of U2''s is suppressed');
select is(public.redact_forgotten_text('Priya Raman called'), 'Priya Raman called', '7 isolation: U1''s forget redacts nothing in U2''s text');
select is((public.get_entity_mentions('priya-raman') ->> 'total')::int, 2, '7 isolation: U2''s quotes about her are intact');
reset role;
select * from public._t_isolation('7 end', 'U2-PRIYA brought cake', 2);

select finish();
rollback;
