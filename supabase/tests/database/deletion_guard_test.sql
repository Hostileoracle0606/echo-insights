-- pgTAP guard for complete account deletion (LM-48). Run: supabase test db
--
-- The deletion guarantee is only as good as its inventory, so this test is
-- built to break when a table is added without a deletion path:
--   1. every table in `public` must be listed in `inventory` below, which
--      says how to find that table's rows for one user. A new table that is
--      not listed fails here; the fix is to add it to the list AND make sure
--      deleting the account removes its rows (a cascade from auth.users or
--      notebooks, or a trigger like on_auth_user_deleted).
--   2. any public table that has a user_id column or a foreign key to
--      auth.users or notebooks must be listed too (catches a typo'd or
--      removed inventory row).
--   3. for every listed table: seed a row for a test user and a bystander,
--      delete the test user the way the app does (delete from auth.users,
--      which is what auth.admin.deleteUser runs), then assert the user's rows
--      are gone and the bystander's remain.
--
--   1a. (deletion queue) `exempt` lists public tables that are keyed by
--      user_id but must OUTLIVE the account on purpose. Each is excluded from
--      checks 1 and 2 and its columns are pinned so it cannot grow personal
--      data unnoticed.
--
--   4. (LM-117) the same for the auth schema, which holds device sessions:
--      every auth table with a user_id column must be in `auth_inventory`
--      and must cascade from auth.users (directly or through auth.sessions),
--      except flow_state, which has no foreign key and is purged by the
--      on_auth_user_deleted trigger. Sessions, refresh tokens, identities,
--      one-time tokens, flow_state and the passkey tables are seeded and
--      checked like section 3.
--      GoTrue versions differ: rows marked `optional` (webauthn_*, the
--      passkey tables, absent from GoTrue 2.186 that CLI 2.75 starts but
--      present from 2.19x and on the hosted project) may be missing; when
--      missing their assertions pass as "absent". Any auth table with a
--      user_id that is NOT listed always fails, whatever the version.
--
--   5. (deletion queue) auth.audit_log_entries has no user_id column (the id
--      is inside the json payload), so it is not in `auth_inventory`; the
--      on_auth_user_deleted trigger purges a user's rows by
--      payload->>'actor_id' and payload->'traits'->>'user_id'. Seeded and
--      checked separately below.
--
-- NOTE: the auth seeds below hard-code GoTrue's column names (sessions,
-- refresh_tokens, identities, one_time_tokens, flow_state); a GoTrue upgrade
-- that renames or adds a required column breaks the seed, not the deletion.
-- The passkey tables are seeded from the catalog instead (pg_temp.seed_auth:
-- user_id plus every NOT NULL column without a default, filled by type).
--
-- To cover a new table: add one `inventory` row, one seed insert, and bump
-- the plan below (2 + 3 per public table, 2 + 3 per seeded auth table,
-- 1 per exempt table, 3 for the audit log).
-- LM-128 (separate branch) must keep notebook_commit_requests in `inventory`.
create extension if not exists pgtap;

begin;
select plan(2 + 3 * 23 + 1 + 2 + 3 * 7 + 3);

-- ── inventory: table → predicate selecting one user's rows ─────────────────
-- Placeholders: %U% user id, %N% that user's notebook id, %S% runtime session id.
create temp table inventory (tbl text primary key, pred text not null) on commit drop;
insert into inventory values
  -- owned directly (user_id) and removed by the cascade from auth.users
  ('profiles',                     'user_id = ''%U%'''),
  ('notebooks',                    'user_id = ''%U%'''),
  ('journal_entries',              'user_id = ''%U%'''),
  ('entities',                     'user_id = ''%U%'''),
  ('relations',                    'user_id = ''%U%'''),
  ('follow_ups',                   'user_id = ''%U%'''),
  ('asked_questions',              'user_id = ''%U%'''),
  ('entity_embeddings',            'user_id = ''%U%'''),
  ('entity_suppressions',          'user_id = ''%U%'''),
  ('suppression_keys',             'user_id = ''%U%'''),
  ('conversation_turns',           'user_id = ''%U%'''),
  ('conversation_runtime_sessions','user_id = ''%U%'''),
  ('session_cards',                'user_id = ''%U%'''),
  ('session_briefs',               'user_id = ''%U%'''),
  ('forget_erase_jobs',            'user_id = ''%U%'''),
  ('memory_facts',                 'user_id = ''%U%'''),
  ('memory_fact_corrections',      'user_id = ''%U%'''),
  ('conversation_state',           'user_id = ''%U%'''),
  ('memory_backfill_progress',     'user_id = ''%U%'''),
  -- owned through a notebook / session only (no user_id): cascade from notebooks
  ('notebook_commit_requests',     'notebook_id = ''%N%'''),
  ('conversation_runtime_inbox',   'session_id = ''%S%'''),
  ('forget_erase_batches',         'job_id in (select id from public.forget_erase_jobs where user_id = ''%U%'')'),
  -- no foreign key at all: keyed by 'user:<uid>' / 'notebook:<id>' text scopes,
  -- purged by the on_auth_user_deleted trigger
  ('retrieve_rate_limits',         'scope in (''user:%U%'', ''notebook:%N%'')');

-- ── exempt: user_id-keyed tables that must outlive the account ─────────────
create temp table exempt (tbl text primary key, why text not null) on commit drop;
insert into exempt values
  -- the deletion queue itself: the row records that the person asked for
  -- deletion and when it was carried out, so it must survive the delete it
  -- triggers (no FK to auth.users). It holds ids, timestamps, a retry count
  -- and a SQLSTATE code only; the column pin below keeps it that way.
  ('account_deletion_requests', 'deletion queue: proof of the request, outlives the user');

select columns_are('public', 'account_deletion_requests',
  array['user_id', 'request_id', 'requested_at', 'completed_at', 'attempts', 'last_error'],
  'exempt account_deletion_requests holds no personal data columns (pinned)');

-- ── 1. the inventory is the whole of `public` ──────────────────────────────
select set_eq(
  $$ select c.relname::text from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r', 'p')
        and c.relname::text not in (select tbl from exempt) $$,
  $$ select tbl from inventory $$,
  'every public table is in the deletion inventory (add new tables to it and to the deletion path)');

-- ── 2. anything that looks user-owned is in the inventory ──────────────────
select is_empty(
  $$ select c.relname::text from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r', 'p')
        and (exists (select 1 from pg_attribute a
                      where a.attrelid = c.oid and a.attname = 'user_id'
                        and a.attnum > 0 and not a.attisdropped)
             or exists (select 1 from pg_constraint k
                         where k.conrelid = c.oid and k.contype = 'f'
                           and k.confrelid in ('auth.users'::regclass, 'public.notebooks'::regclass)))
        and c.relname::text not in (select tbl from inventory)
        and c.relname::text not in (select tbl from exempt) $$,
  'every table with a user_id or a foreign key to auth.users or notebooks is in the inventory');

-- ── 4a. auth tables that carry a user id (device sessions live here) ──────
create temp table auth_inventory (tbl text primary key, pred text not null, seeded bool not null,
                                   optional bool not null default false) on commit drop;
insert into auth_inventory values
  ('sessions',            'user_id = ''%U%''', true,  false),  -- what list_my_sessions reads
  ('refresh_tokens',      'user_id = ''%U%''', true,  false),  -- varchar user_id; cascades from sessions
  ('identities',          'user_id = ''%U%''', true,  false),
  ('one_time_tokens',     'user_id = ''%U%''', true,  false),
  ('flow_state',          'user_id = ''%U%''', true,  false),  -- no FK: purged by trigger
  ('mfa_factors',         'user_id = ''%U%''', false, false),  -- FK cascade, checked in the catalog
  ('oauth_authorizations','user_id = ''%U%''', false, false),
  ('oauth_consents',      'user_id = ''%U%''', false, false),
  -- passkeys (LM-127): FK to auth.users ON DELETE CASCADE in GoTrue 2.191;
  -- not present in older GoTrue images, hence optional
  ('webauthn_challenges', 'user_id = ''%U%''', true,  true),
  ('webauthn_credentials','user_id = ''%U%''', true,  true);

create function pg_temp.auth_present(p_tbl text) returns boolean language sql stable as
  $$ select to_regclass(format('auth.%I', p_tbl)) is not null $$;

-- Exactly the listed tables, minus optional ones this GoTrue version lacks:
-- an unlisted auth table with a user_id fails, and so does a missing
-- required one; the result does not depend on which GoTrue image is running.
select set_eq(
  $$ select c.relname::text from pg_class c
       join pg_attribute a on a.attrelid = c.oid
      where c.relnamespace = 'auth'::regnamespace and c.relkind in ('r', 'p')
        and a.attname = 'user_id' and a.attnum > 0 and not a.attisdropped $$,
  $$ select tbl from auth_inventory where not optional or pg_temp.auth_present(tbl) $$,
  'every auth table with a user_id column is in the auth deletion inventory (a new GoTrue table must be added here)');

select is_empty(
  $$ select c.relname::text from pg_class c
       join pg_attribute a on a.attrelid = c.oid
      where c.relnamespace = 'auth'::regnamespace and c.relkind in ('r', 'p')
        and a.attname = 'user_id' and a.attnum > 0 and not a.attisdropped
        and c.relname::text <> 'flow_state'
        and not exists (select 1 from pg_constraint k
                         where k.conrelid = c.oid and k.contype = 'f' and k.confdeltype = 'c'
                           and k.confrelid in ('auth.users'::regclass, 'auth.sessions'::regclass)) $$,
  'every auth table with a user_id cascades from auth.users or auth.sessions (flow_state is trigger-purged and seeded below)');

-- ── seed: U is deleted, V is a bystander ───────────────────────────────────
create temp table who (name text primary key, uid uuid, nid uuid, sid uuid) on commit drop;
insert into who values
  ('U', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', 'a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2'),
  ('V', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1', 'b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2');

insert into auth.users (id) select uid from who;   -- the profiles trigger adds profiles
-- Columns added after the table: they go with their row, and are set here so
-- a row carrying them is what gets deleted.
update public.profiles p
   set transcript_retention_days = 30,
       transcript_retention_offered_at = now(),
       privacy_screen_seen_at = now()
  from who where p.user_id = who.uid;
insert into public.notebooks (id, user_id, title, started_at, transcript_forgotten_at)
  select nid, uid, 'nb ' || name, now(), now() from who;
insert into public.journal_entries (user_id, notebook_id, text, created_at)
  select uid, nid, 'entry', now() from who;
insert into public.entities (id, user_id, notebook_id, name, type, first_seen, last_seen)
  select 'maya', uid, nid, 'Maya', 'person', now(), now() from who;
insert into public.relations (id, user_id, notebook_id, source_id, target_id, label)
  select 'r1', uid, nid, 'maya', 'maya', 'knows' from who;
insert into public.follow_ups (user_id, notebook_id, question)
  select uid, nid, 'q?' from who;
insert into public.asked_questions (user_id, notebook_id, question)
  select uid, nid, 'q?' from who;
insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
  select nid, 'maya', uid, array_fill(0.0::real, array[384])::vector, 'm', 'h' from who;
insert into public.entity_suppressions (user_id, entity_hash)
  select uid, 'hash' from who;
insert into public.suppression_keys (user_id, key)
  select uid, '\x00'::bytea from who;
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at)
  select nid, 't1', uid, 'user', 'hello', now() from who;
insert into public.conversation_runtime_sessions (id, notebook_id, user_id, device_id, mode)
  select sid, nid, uid, gen_random_uuid(), 'wiki' from who;
insert into public.conversation_runtime_inbox (session_id, sequence, event_id, observation)
  select sid, 1, gen_random_uuid(), '{}'::jsonb from who;
insert into public.notebook_commit_requests (notebook_id, request_id, request_hash, result)
  select nid, gen_random_uuid(), 'h', '{}'::jsonb from who;
insert into public.session_cards (notebook_id, user_id, conversation_mode, source_revision, card)
  select nid, uid, 'just_talk', 1, '{}'::jsonb from who;
insert into public.session_briefs (user_id, source_notebook_id, source_revision, brief, audio, sample_rate)
  select uid, nid, 1, '{}'::jsonb, '\x00', 24000 from who;
insert into public.forget_erase_jobs (user_id, entity_hash, hashes, max_words)
  select uid, 'hash', array['h'], 2 from who;
insert into public.forget_erase_batches (job_id, batch_no, request_hash, result)
  select j.id, 1, 'h', '{}'::jsonb from public.forget_erase_jobs j join who on j.user_id = who.uid;
insert into public.memory_facts (user_id, entity_id, attribute, status, stated_at, value_text, source_notebook_id)
  select uid, 'maya', 'city', 'confirmed', now(), 'Lisbon', nid from who;
insert into public.memory_fact_corrections (user_id, fact_id, change, read_back)
  select f.user_id, f.id, '{}'::jsonb, 'r' from public.memory_facts f join who on f.user_id = who.uid;
insert into public.conversation_state (notebook_id, user_id, state)
  select nid, uid, '{}'::jsonb from who;
insert into public.memory_backfill_progress (user_id, last_created_at, last_entry_id)
  select uid, now(), gen_random_uuid() from who;
insert into public.retrieve_rate_limits (scope, window_start, count)
  select s, now(), 1 from who, unnest(array['user:' || uid, 'notebook:' || nid]) s;

-- auth rows (device sessions and friends), one session + one token per user
insert into auth.sessions (id, user_id, created_at, updated_at, user_agent)
  select sid, uid, now(), now(), 'Dart/3.5 (dart:io)' from who;
insert into auth.refresh_tokens (token, user_id, session_id, revoked)
  select 'tok-' || name, uid::text, sid, false from who;
insert into auth.identities (provider_id, user_id, identity_data, provider)
  select uid::text, uid, '{}'::jsonb, 'apple' from who;
insert into auth.one_time_tokens (id, user_id, token_type, token_hash, relates_to)
  select gen_random_uuid(), uid, 'recovery_token', 'hash-' || name, 'x@example.test' from who;
insert into auth.flow_state (id, user_id, auth_code, code_challenge_method, code_challenge,
                             provider_type, provider_access_token, authentication_method)
  select gen_random_uuid(), uid, 'code-' || name, 's256', 'chal', 'apple', 'tok', 'oauth' from who;
-- passkey tables (when this GoTrue has them), seeded from the catalog so a
-- new required column does not break the seed: user_id plus every NOT NULL
-- column without a default, filled by type; p_over gives literal values for
-- columns with a CHECK or other meaning.
create function pg_temp.seed_auth(p_tbl text, p_uid uuid, p_over jsonb default '{}') returns void
language plpgsql as $$
declare
  cols text[] := array['user_id'];
  vals text[] := array[quote_literal(p_uid) || '::uuid'];
  c record;
  v text;
begin
  for c in
    select a.attname::text as col, format_type(a.atttypid, a.atttypmod) as typ
      from pg_attribute a
     where a.attrelid = format('auth.%I', p_tbl)::regclass
       and a.attnum > 0 and not a.attisdropped and a.attnotnull and not a.atthasdef
       and a.attidentity = '' and a.attgenerated = '' and a.attname <> 'user_id'
     order by a.attnum
  loop
    if p_over ? c.col then
      v := quote_literal(p_over->>c.col) || '::' || c.typ;
    else
      v := case
        when c.typ = 'uuid' then 'gen_random_uuid()'
        when c.typ in ('text', 'character varying') or c.typ like 'character varying(%' then 'gen_random_uuid()::text'
        when c.typ = 'bytea' then 'convert_to(gen_random_uuid()::text, ''UTF8'')'
        when c.typ in ('jsonb', 'json') then '''{}''::' || c.typ
        when c.typ like 'timestamp%' then 'now() + interval ''1 hour'''
        when c.typ = 'boolean' then 'false'
        when c.typ in ('smallint', 'integer', 'bigint', 'numeric') then '0'
      end;
      if v is null then
        raise exception 'seed_auth: no filler for %.% (%)', p_tbl, c.col, c.typ;
      end if;
    end if;
    cols := cols || quote_ident(c.col);
    vals := vals || v;
  end loop;
  execute format('insert into auth.%I (%s) values (%s)', p_tbl,
                 array_to_string(cols, ', '), array_to_string(vals, ', '));
end $$;

do $$
begin
  perform pg_temp.seed_auth(t.tbl, who.uid, t.over)
     from who,
          (values ('webauthn_credentials', '{}'::jsonb),
                  ('webauthn_challenges',  '{"challenge_type": "authentication"}'::jsonb)) t(tbl, over)
    where pg_temp.auth_present(t.tbl);
end $$;

-- audit log: one row with the user as actor (a login), one where an admin
-- acted on the user (the id sits in traits.user_id)
insert into auth.audit_log_entries (id, payload, created_at)
  select gen_random_uuid(),
         json_build_object('actor_id', uid::text, 'actor_username', 'x', 'action', 'login', 'log_type', 'account'),
         now() from who
  union all
  select gen_random_uuid(),
         json_build_object('actor_id', '00000000-0000-0000-0000-000000000000', 'action', 'user_modified',
                           'log_type', 'user', 'traits', json_build_object('user_id', uid::text)),
         now() from who;

-- a user's audit rows, by either place their id appears
create function pg_temp.audit_rows_of(p_who text) returns bigint language sql as $$
  select count(*) from auth.audit_log_entries a, who
   where who.name = p_who
     and (a.payload->>'actor_id' = who.uid::text or a.payload->'traits'->>'user_id' = who.uid::text)
$$;

-- rows a user has in a table, by the inventory predicate
create function pg_temp.rows_of(p_tbl text, p_who text) returns bigint
language plpgsql as $$
declare
  w who%rowtype;
  p text;
  n bigint;
begin
  select * into w from who where name = p_who;
  select replace(replace(replace(pred, '%U%', w.uid::text), '%N%', w.nid::text), '%S%', w.sid::text)
    into p from inventory where tbl = p_tbl;
  execute format('select count(*) from public.%I where %s', p_tbl, p) into n;
  return n;
end $$;

-- rows a user has in an auth table, by the auth_inventory predicate (user_id only)
create function pg_temp.auth_rows_of(p_tbl text, p_who text) returns bigint
language plpgsql as $$
declare
  w who%rowtype;
  p text;
  n bigint;
begin
  if not pg_temp.auth_present(p_tbl) then
    return null;                       -- optional table absent in this GoTrue version
  end if;
  select * into w from who where name = p_who;
  select replace(pred, '%U%', w.uid::text) into p from auth_inventory where tbl = p_tbl;
  execute format('select count(*) from auth.%I where %s', p_tbl, p) into n;
  return n;
end $$;

-- ── 3. seeded, then deleted the way the app does it ────────────────────────
select ok(pg_temp.rows_of(tbl, 'U') > 0 and pg_temp.rows_of(tbl, 'V') > 0,
          tbl || ': seeded for both users')
  from inventory order by tbl;

-- (an absent optional table yields null -> coalesce -> pass, labelled "absent")
create function pg_temp.absent(p_tbl text) returns text language sql stable as
  $$ select case when pg_temp.auth_present(p_tbl) then '' else ' (absent in this GoTrue version)' end $$;

select ok(coalesce(pg_temp.auth_rows_of(tbl, 'U') > 0 and pg_temp.auth_rows_of(tbl, 'V') > 0, true),
          'auth.' || tbl || ': seeded for both users' || pg_temp.absent(tbl))
  from auth_inventory where seeded order by tbl;
select ok(pg_temp.audit_rows_of('U') = 2 and pg_temp.audit_rows_of('V') = 2,
          'auth.audit_log_entries: seeded for both users (actor and traits rows)');

delete from auth.users where id = (select uid from who where name = 'U');

select is(pg_temp.rows_of(tbl, 'U'), 0::bigint, tbl || ': nothing left for the deleted account')
  from inventory order by tbl;

select ok(pg_temp.rows_of(tbl, 'V') > 0, tbl || ': a bystander''s rows are untouched')
  from inventory order by tbl;

-- ── 4b. the seeded auth tables, after the delete ────────────────────────────
select is(coalesce(pg_temp.auth_rows_of(tbl, 'U'), 0), 0::bigint,
          'auth.' || tbl || ': nothing left for the deleted account' || pg_temp.absent(tbl))
  from auth_inventory where seeded order by tbl;
select ok(coalesce(pg_temp.auth_rows_of(tbl, 'V') > 0, true),
          'auth.' || tbl || ': a bystander''s rows are untouched' || pg_temp.absent(tbl))
  from auth_inventory where seeded order by tbl;

-- ── 5. the audit log, after the delete ──────────────────────────────────────
select is(pg_temp.audit_rows_of('U'), 0::bigint, 'auth.audit_log_entries: nothing left for the deleted account');
select is(pg_temp.audit_rows_of('V'), 2::bigint, 'auth.audit_log_entries: a bystander''s rows are untouched');

select * from finish();
rollback;
