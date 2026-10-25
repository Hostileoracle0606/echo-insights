-- Server-side execution time of every database call on a user's path, for
-- one heavy user: 200 notebooks, 15 entities each (1,500 distinct slugs, so
-- the user-wide merge has real overlap), 30 journal entries and 60 turns per
-- notebook, and an embedding per entity row.
--
-- Everything runs in one transaction that is rolled back, so it leaves no
-- data behind. Calls run as `authenticated` with the user's JWT claim, so RLS
-- applies exactly as in production. Output: one PERF notice per call.
--
-- Run against the local stack (needs Docker and `supabase start`):
--   docker exec -i supabase_db_bjoevzvsdlhlcjywpyfx psql -U postgres -d postgres -q < supabase/tests/perf/rpc_timings.sql
--
-- These are database execution times only. Add one network round trip per
-- call (edge function or Lambda → Postgres, same region: ~2–10 ms; PostgREST
-- adds a few ms of its own).
\set ON_ERROR_STOP on
begin;

insert into auth.users (id) values ('aaaaaaaa-0000-0000-0000-000000000001');

insert into public.notebooks (id, user_id, title, started_at)
select ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'aaaaaaaa-0000-0000-0000-000000000001', 'Notebook ' || n,
       now() - make_interval(days => 200 - n)
from generate_series(1, 200) n;

-- 15 entities per notebook, slugs drawn from a pool of 1,500.
insert into public.entities (id, user_id, notebook_id, name, type, description, mentions, first_seen, last_seen)
select 'e' || ((n * 7 + k * 13) % 1500),
       'aaaaaaaa-0000-0000-0000-000000000001',
       ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'Entity ' || ((n * 7 + k * 13) % 1500),
       (array['person','place','project','concept','activity','emotion'])[1 + (k % 6)],
       case when k % 2 = 0 then 'A short factual description of this entity.' end,
       1 + (k % 9), now() - make_interval(days => 200 - n), now() - make_interval(days => 200 - n)
from generate_series(1, 200) n, generate_series(1, 15) k;

insert into public.relations (id, user_id, notebook_id, source_id, target_id, label)
select 'e' || ((n * 7 + k * 13) % 1500) || '__related_to__e' || ((n * 7 + (k + 1) * 13) % 1500),
       'aaaaaaaa-0000-0000-0000-000000000001',
       ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'e' || ((n * 7 + k * 13) % 1500), 'e' || ((n * 7 + (k + 1) * 13) % 1500), 'related_to'
from generate_series(1, 200) n, generate_series(1, 14) k;

insert into public.journal_entries (user_id, notebook_id, text, created_at, entity_ids)
select 'aaaaaaaa-0000-0000-0000-000000000001',
       ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'I talked about Entity ' || ((n * 7 + (j % 15 + 1) * 13) % 1500) || ' in turn ' || j,
       now() - make_interval(days => 200 - n, mins => -j),
       array['e' || ((n * 7 + (j % 15 + 1) * 13) % 1500), 'e' || ((n * 7 + ((j + 1) % 15 + 1) * 13) % 1500)]
from generate_series(1, 200) n, generate_series(1, 30) j;

insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at)
select ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 't' || j || s,
       'aaaaaaaa-0000-0000-0000-000000000001', s,
       case when s = 'user' then 'I talked about Entity ' || ((n * 7 + (j % 15 + 1) * 13) % 1500) || ' in turn ' || j
            else 'Lumen reply ' || j end,
       now() - make_interval(days => 200 - n, mins => -j)
from generate_series(1, 200) n, generate_series(1, 30) j, unnest(array['user','assistant']) s;

insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
select e.notebook_id, e.id, e.user_id,
       (select array_agg(random())::real[] from generate_series(1, 384) g where g > 0 * length(e.id))::vector,
       'gte-small@1', md5(e.id)
from public.entities e where e.user_id = 'aaaaaaaa-0000-0000-0000-000000000001';

analyze public.entities, public.relations, public.journal_entries, public.conversation_turns, public.entity_embeddings, public.notebooks;

-- Times `sql` `runs` times after one warm-up and prints median and worst.
create or replace function pg_temp.bench(label text, sql text, runs int default 9) returns void
language plpgsql as $$
declare
  samples double precision[] := '{}';
  t0 timestamptz;
begin
  execute sql;
  for i in 1..runs loop
    t0 := clock_timestamp();
    execute sql;
    samples := samples || (extract(epoch from clock_timestamp() - t0) * 1000);
  end loop;
  select array_agg(x order by x) into samples from unnest(samples) x;
  raise notice 'PERF % median=%ms worst=%ms', label,
    round(samples[(runs + 1) / 2]::numeric, 2), round(samples[runs]::numeric, 2);
end $$;

-- Service role: the embedding match (the edge function calls it with the service key).
select pg_temp.bench('match_user_entity_embeddings (recall seeds)',
  $q$select * from public.match_user_entity_embeddings('aaaaaaaa-0000-0000-0000-000000000001',
       (select embedding from public.entity_embeddings limit 1), 12, 'gte-small@1')$q$);

grant execute on function pg_temp.bench(text, text, int) to authenticated;
set local role authenticated;
set local request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';

-- Opening a notebook (the app runs these two one after the other today).
select pg_temp.bench('get_notebook_snapshot (open notebook)',
  $q$select public.get_notebook_snapshot('bbbbbbbb-0000-0000-0000-000000000200')$q$);
select pg_temp.bench('conversation_turns latest 500 (open notebook)',
  $q$select turn_id, speaker, text, spoken_at from public.conversation_turns
     where notebook_id = 'bbbbbbbb-0000-0000-0000-000000000200' order by spoken_at desc limit 500$q$);

-- Live recall (get_relevant_memory, user scope), in the handler's order.
select pg_temp.bench('notebooks select id (recall ownership check)',
  $q$select id from public.notebooks where id = 'bbbbbbbb-0000-0000-0000-000000000200'$q$);
select pg_temp.bench('bump_retrieve_rate (recall)',
  $q$select public.bump_retrieve_rate('bbbbbbbb-0000-0000-0000-000000000200')$q$);
select pg_temp.bench('get_user_graph 2000 (recall)',
  $q$select public.get_user_graph(null, 2000)$q$, 5);
select pg_temp.bench('get_entity_mentions x1 (recall quotes)',
  $q$select public.get_entity_mentions('e700', 5)$q$);

-- Leaving: close-session reads user_entities for the candidate list.
select pg_temp.bench('user_entities for 15 ids (close-session)',
  $q$select id, notebook_count from public.user_entities
     where id in (select id from public.entities where notebook_id = 'bbbbbbbb-0000-0000-0000-000000000200')$q$, 5);

-- One user turn's commit (applyTurn), each run against the current revision.
create or replace function pg_temp.commit_once() returns void language plpgsql as $$
declare rev bigint;
begin
  select revision into rev from public.notebooks where id = 'bbbbbbbb-0000-0000-0000-000000000200';
  perform public.commit_notebook('bbbbbbbb-0000-0000-0000-000000000200', rev, gen_random_uuid(),
    jsonb_build_object('kind', 'applyTurn',
      'entry', jsonb_build_object('text', 'Had coffee with Maya about Atlas.', 'entityIds', jsonb_build_array('maya'), 'relationIds', '[]'::jsonb),
      'entities', jsonb_build_array(jsonb_build_object('id', 'maya', 'name', 'Maya', 'type', 'person', 'metadata', '{}'::jsonb,
        'mentions', 1, 'firstSeen', now(), 'lastSeen', now())),
      'relations', '[]'::jsonb));
end $$;
grant execute on function pg_temp.commit_once() to authenticated;
select pg_temp.bench('commit_notebook applyTurn (every user turn)', $q$select pg_temp.commit_once()$q$);

rollback;
