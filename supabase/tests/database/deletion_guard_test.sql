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
--   4. (LM-117) the same for the auth schema, which holds device sessions:
--      every auth table with a user_id column must be in `auth_inventory`
--      and must cascade from auth.users (directly or through auth.sessions),
--      except flow_state, which has no foreign key and is purged by the
--      on_auth_user_deleted trigger. Sessions, refresh tokens, identities,
--      one-time tokens and flow_state are seeded and checked like section 3.
--
-- NOTE: the auth seeds below hard-code GoTrue's column names (sessions,
-- refresh_tokens, identities, one_time_tokens, flow_state); a GoTrue upgrade
-- that renames or adds a required column breaks the seed, not the deletion.
--
-- To cover a new table: add one `inventory` row, one seed insert, and bump
-- the plan below (2 + 3 per public table, 2 + 3 per seeded auth table).
-- LM-128 (separate branch) must keep notebook_commit_requests in `inventory`.
create extension if not exists pgtap;

begin;
select plan(2 + 3 * 19 + 2 + 3 * 5);

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
  -- owned through a notebook / session only (no user_id): cascade from notebooks
  ('notebook_commit_requests',     'notebook_id = ''%N%'''),
  ('conversation_runtime_inbox',   'session_id = ''%S%'''),
  ('forget_erase_batches',         'job_id in (select id from public.forget_erase_jobs where user_id = ''%U%'')'),
  -- no foreign key at all: keyed by 'user:<uid>' / 'notebook:<id>' text scopes,
  -- purged by the on_auth_user_deleted trigger
  ('retrieve_rate_limits',         'scope in (''user:%U%'', ''notebook:%N%'')');

-- ── 1. the inventory is the whole of `public` ──────────────────────────────
select set_eq(
  $$ select c.relname::text from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r', 'p') $$,
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
        and c.relname::text not in (select tbl from inventory) $$,
  'every table with a user_id or a foreign key to auth.users or notebooks is in the inventory');

-- ── 4a. auth tables that carry a user id (device sessions live here) ──────
create temp table auth_inventory (tbl text primary key, pred text not null, seeded bool not null) on commit drop;
insert into auth_inventory values
  ('sessions',            'user_id = ''%U%''', true),   -- what list_my_sessions reads
  ('refresh_tokens',      'user_id = ''%U%''', true),   -- varchar user_id; cascades from sessions
  ('identities',          'user_id = ''%U%''', true),
  ('one_time_tokens',     'user_id = ''%U%''', true),
  ('flow_state',          'user_id = ''%U%''', true),   -- no FK: purged by trigger
  ('mfa_factors',         'user_id = ''%U%''', false),  -- FK cascade, checked in the catalog
  ('oauth_authorizations','user_id = ''%U%''', false),
  ('oauth_consents',      'user_id = ''%U%''', false),
  ('webauthn_challenges', 'user_id = ''%U%''', false),
  ('webauthn_credentials','user_id = ''%U%''', false);

select set_eq(
  $$ select c.relname::text from pg_class c
       join pg_attribute a on a.attrelid = c.oid
      where c.relnamespace = 'auth'::regnamespace and c.relkind in ('r', 'p')
        and a.attname = 'user_id' and a.attnum > 0 and not a.attisdropped $$,
  $$ select tbl from auth_inventory $$,
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
  select * into w from who where name = p_who;
  select replace(pred, '%U%', w.uid::text) into p from auth_inventory where tbl = p_tbl;
  execute format('select count(*) from auth.%I where %s', p_tbl, p) into n;
  return n;
end $$;

-- ── 3. seeded, then deleted the way the app does it ────────────────────────
select ok(pg_temp.rows_of(tbl, 'U') > 0 and pg_temp.rows_of(tbl, 'V') > 0,
          tbl || ': seeded for both users')
  from inventory order by tbl;

select ok(pg_temp.auth_rows_of(tbl, 'U') > 0 and pg_temp.auth_rows_of(tbl, 'V') > 0,
          'auth.' || tbl || ': seeded for both users')
  from auth_inventory where seeded order by tbl;

delete from auth.users where id = (select uid from who where name = 'U');

select is(pg_temp.rows_of(tbl, 'U'), 0::bigint, tbl || ': nothing left for the deleted account')
  from inventory order by tbl;

select ok(pg_temp.rows_of(tbl, 'V') > 0, tbl || ': a bystander''s rows are untouched')
  from inventory order by tbl;

-- ── 4b. the seeded auth tables, after the delete ────────────────────────────
select is(pg_temp.auth_rows_of(tbl, 'U'), 0::bigint, 'auth.' || tbl || ': nothing left for the deleted account')
  from auth_inventory where seeded order by tbl;
select ok(pg_temp.auth_rows_of(tbl, 'V') > 0, 'auth.' || tbl || ': a bystander''s rows are untouched')
  from auth_inventory where seeded order by tbl;

select * from finish();
rollback;
