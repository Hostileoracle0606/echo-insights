-- User-wide memory read model (LM-06).
--
-- Memory is stored per notebook: the same slug in three conversations is
-- three entities rows. This adds a read layer that merges them by slug across
-- all of a user's notebooks (archived ones included). Nothing here writes;
-- commit_notebook stays the only write path, per notebook, unchanged.

-- ────────────────────────────────────────────────────────────
-- 1. Indexes for user-scoped reads
-- ────────────────────────────────────────────────────────────
create index entities_user_id_idx on public.entities (user_id, id);
create index relations_user_id_idx on public.relations (user_id, id);
create index entity_embeddings_user_model_idx on public.entity_embeddings (user_id, embedding_model);

-- ────────────────────────────────────────────────────────────
-- 2. user_entities: one row per (user_id, slug)
--
-- security_invoker is what keeps this safe: without it the view runs with its
-- owner's rights, bypasses the owner-only RLS on entities and returns every
-- user's memory. With it, the caller's RLS applies to the underlying rows.
-- ────────────────────────────────────────────────────────────
create view public.user_entities with (security_invoker = true) as
select
  e.user_id,
  e.id,
  (array_agg(e.name order by e.last_seen desc, e.notebook_id))[1] as name,
  (array_agg(e.type order by e.last_seen desc, e.notebook_id))[1] as type,
  (array_agg(e.description order by e.last_seen desc, e.notebook_id)
     filter (where e.description is not null))[1] as description,
  -- entities.mentions counts per notebook, so the sum is the user-wide count.
  sum(e.mentions)::int as mentions,
  min(e.first_seen) as first_seen,
  max(e.last_seen) as last_seen,
  array_agg(e.notebook_id order by e.first_seen, e.notebook_id) as notebook_ids,
  count(*)::int as notebook_count
from public.entities e
group by e.user_id, e.id;

-- ────────────────────────────────────────────────────────────
-- 3. user_relations: one row per (user_id, relation id)
--
-- active: some notebook holds the relation unsuperseded, and that row was
-- created after the latest supersession of the same id in any notebook. So a
-- contradiction in a later conversation wins, and re-stating the relation
-- even later revives it. Comparing the latest unsuperseded created_at with
-- the latest superseded_at is the same test in one aggregate.
-- ────────────────────────────────────────────────────────────
create view public.user_relations with (security_invoker = true) as
select
  r.user_id,
  r.id,
  (array_agg(r.source_id order by r.created_at desc, r.notebook_id))[1] as source_id,
  (array_agg(r.target_id order by r.created_at desc, r.notebook_id))[1] as target_id,
  (array_agg(r.label order by r.created_at desc, r.notebook_id))[1] as label,
  array_agg(r.notebook_id order by r.created_at, r.notebook_id) as notebook_ids,
  min(r.created_at) as first_created_at,
  coalesce(
    max(r.created_at) filter (where r.superseded_at is null)
      > coalesce(max(r.superseded_at), '-infinity'::timestamptz),
    false
  ) as active
from public.relations r
group by r.user_id, r.id;

-- ────────────────────────────────────────────────────────────
-- 4. View grants
-- ────────────────────────────────────────────────────────────
revoke all on public.user_entities from anon, authenticated;
revoke all on public.user_relations from anon, authenticated;
grant select on public.user_entities to authenticated;
grant select on public.user_relations to authenticated;

-- ────────────────────────────────────────────────────────────
-- 5. get_user_graph: the caller's merged graph
--
-- Entities: the top p_limit (clamped 1–2000) by mentions, filtered to p_types
-- when given (null or empty = all types). Relations: active ones whose
-- endpoints are both in the returned set. entityCount / relationCount are the
-- totals for the type filter before the limit is applied.
-- ────────────────────────────────────────────────────────────
create or replace function public.get_user_graph(
  p_types text[] default null,
  p_limit int default 500
) returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  with filtered as (
    select ue.id, ue.name, ue.type, ue.description, ue.mentions,
           ue.first_seen, ue.last_seen, ue.notebook_count
    from public.user_entities ue
    where ue.user_id = auth.uid()
      and (p_types is null or cardinality(p_types) = 0 or ue.type = any(p_types))
  ),
  picked as (
    select f.*
    from filtered f
    order by f.mentions desc, f.last_seen desc, f.id
    limit least(greatest(coalesce(p_limit, 500), 1), 2000)
  ),
  active_relations as (
    select ur.id, ur.source_id, ur.target_id, ur.label
    from public.user_relations ur
    where ur.user_id = auth.uid()
      and ur.active
      and ur.source_id in (select id from filtered)
      and ur.target_id in (select id from filtered)
  )
  select jsonb_build_object(
    'entityCount', (select count(*) from filtered),
    'relationCount', (select count(*) from active_relations),
    'entities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.name, 'type', p.type, 'description', p.description,
        'mentions', p.mentions, 'firstSeen', p.first_seen, 'lastSeen', p.last_seen,
        'notebookCount', p.notebook_count
      ) order by p.mentions desc, p.last_seen desc, p.id)
      from picked p
    ), '[]'::jsonb),
    'relations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'source', r.source_id, 'target', r.target_id, 'label', r.label
      ) order by r.id)
      from active_relations r
      where r.source_id in (select id from picked)
        and r.target_id in (select id from picked)
    ), '[]'::jsonb)
  );
$$;

-- ────────────────────────────────────────────────────────────
-- 6. get_entity_mentions: where the caller talked about one entity
--
-- Mentions are the journal entries whose entity_ids contain the slug, newest
-- first, paged with p_before (exclusive; p_limit clamped 1–100).
--
-- Entries don't record which turn produced them, so turnId/spokenAt are a
-- best-effort match: the user turn in the same notebook with exactly the same
-- text, the latest one spoken at or before the entry was committed. Null when
-- nothing matches, which is expected for notebooks older than
-- conversation_turns (2026-09-28).
-- ────────────────────────────────────────────────────────────
create or replace function public.get_entity_mentions(
  p_entity_id text,
  p_limit int default 20,
  p_before timestamptz default null
) returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  with hits as (
    select je.id, je.notebook_id, je.text, je.created_at
    from public.journal_entries je
    where je.user_id = auth.uid()
      and je.entity_ids @> array[p_entity_id]
  ),
  page as (
    select h.*
    from hits h
    where p_before is null or h.created_at < p_before
    order by h.created_at desc, h.id desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  )
  select jsonb_build_object(
    'total', (select count(*) from hits),
    'mentions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entryId', p.id, 'notebookId', p.notebook_id,
        'notebookTitle', nb.title, 'notebookStartedAt', nb.started_at,
        'createdAt', p.created_at, 'excerpt', left(p.text, 280),
        'turnId', t.turn_id, 'spokenAt', t.spoken_at
      ) order by p.created_at desc, p.id desc)
      from page p
      join public.notebooks nb on nb.id = p.notebook_id
      left join lateral (
        select ct.turn_id, ct.spoken_at
        from public.conversation_turns ct
        where ct.notebook_id = p.notebook_id
          and ct.speaker = 'user'
          and ct.text = p.text
          and ct.spoken_at <= p.created_at
        order by ct.spoken_at desc
        limit 1
      ) t on true
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.get_user_graph(text[], int) from public, anon;
grant execute on function public.get_user_graph(text[], int) to authenticated;

revoke all on function public.get_entity_mentions(text, int, timestamptz) from public, anon;
grant execute on function public.get_entity_mentions(text, int, timestamptz) to authenticated;

-- ────────────────────────────────────────────────────────────
-- 7. match_user_entity_embeddings: user-wide semantic match
--
-- Exact cosine scan across all of the user's notebooks, model-filtered,
-- keeping each entity's best-scoring notebook, clamped to 1–50 results.
-- Service-role only, like match_entity_embeddings: it takes p_user_id
-- explicitly because the service role has no auth.uid(), so the calling edge
-- function is responsible for proving who the user is.
-- ────────────────────────────────────────────────────────────
create or replace function public.match_user_entity_embeddings(
  p_user_id uuid, p_query vector(384), p_limit int, p_model text
) returns table (entity_id text, notebook_id uuid, score float)
language sql stable as $$
  select b.entity_id, b.notebook_id, b.score
  from (
    select distinct on (e.entity_id)
      e.entity_id, e.notebook_id, 1 - (e.embedding <=> p_query) as score
    from public.entity_embeddings e
    where e.user_id = p_user_id
      and e.embedding_model = p_model
    order by e.entity_id, e.embedding <=> p_query, e.notebook_id
  ) b
  order by b.score desc, b.entity_id
  limit least(greatest(p_limit, 1), 50);
$$;
revoke all on function public.match_user_entity_embeddings(uuid, vector, int, text) from public, anon, authenticated;
grant execute on function public.match_user_entity_embeddings(uuid, vector, int, text) to service_role;
