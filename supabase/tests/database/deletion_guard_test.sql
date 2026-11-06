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
-- To cover a new table: add one `inventory` row, one seed insert, and bump
-- the plan below (2 + 3 per table).
create extension if not exists pgtap;

begin;
select plan(2 + 3 * 16);

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
  ('conversation_turns',           'user_id = ''%U%'''),
  ('conversation_runtime_sessions','user_id = ''%U%'''),
  ('session_cards',                'user_id = ''%U%'''),
  ('session_briefs',               'user_id = ''%U%'''),
  -- owned through a notebook / session only (no user_id): cascade from notebooks
  ('notebook_commit_requests',     'notebook_id = ''%N%'''),
  ('conversation_runtime_inbox',   'session_id = ''%S%'''),
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

-- ── seed: U is deleted, V is a bystander ───────────────────────────────────
create temp table who (name text primary key, uid uuid, nid uuid, sid uuid) on commit drop;
insert into who values
  ('U', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1', 'a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2'),
  ('V', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1', 'b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2');

insert into auth.users (id) select uid from who;   -- the profiles trigger adds profiles
insert into public.notebooks (id, user_id, title, started_at)
  select nid, uid, 'nb ' || name, now() from who;
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
insert into public.entity_suppressions (user_id, entity_id)
  select uid, 'maya' from who;
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
insert into public.retrieve_rate_limits (scope, window_start, count)
  select s, now(), 1 from who, unnest(array['user:' || uid, 'notebook:' || nid]) s;

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

-- ── 3. seeded, then deleted the way the app does it ────────────────────────
select ok(pg_temp.rows_of(tbl, 'U') > 0 and pg_temp.rows_of(tbl, 'V') > 0,
          tbl || ': seeded for both users')
  from inventory order by tbl;

delete from auth.users where id = (select uid from who where name = 'U');

select is(pg_temp.rows_of(tbl, 'U'), 0::bigint, tbl || ': nothing left for the deleted account')
  from inventory order by tbl;

select ok(pg_temp.rows_of(tbl, 'V') > 0, tbl || ': a bystander''s rows are untouched')
  from inventory order by tbl;

select * from finish();
rollback;
