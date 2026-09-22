create extension if not exists vector;
create extension if not exists pg_net;

-- Per-entity embedding, versioned by embedding_model. Operational state:
-- clients get zero direct access (RLS on, no policy, grants revoked).
create table public.entity_embeddings (
  notebook_id     uuid not null references public.notebooks(id) on delete cascade,
  entity_id       text not null,
  user_id         uuid not null references auth.users(id) on delete cascade,
  embedding       vector(384) not null,
  embedding_model text not null,
  content_hash    text not null,
  updated_at      timestamptz not null default now(),
  primary key (notebook_id, entity_id)
);

alter table public.entity_embeddings enable row level security;
revoke all on table public.entity_embeddings from anon, authenticated;

-- Per-notebook btree; exact scan within a notebook (no HNSW at this scale).
create index entity_embeddings_notebook on public.entity_embeddings (notebook_id);

-- Service-role-only match: exact per-notebook cosine, model-filtered, clamped.
-- Not granted to authenticated → cannot be called directly to bypass the edge
-- fn's ownership + rate-limit gates.
create or replace function public.match_entity_embeddings(
  p_notebook_id uuid, p_query vector(384), p_limit int, p_model text
) returns table (entity_id text, score float)
language sql stable as $$
  select e.entity_id, 1 - (e.embedding <=> p_query) as score
  from public.entity_embeddings e
  where e.notebook_id = p_notebook_id
    and e.embedding_model = p_model
  order by e.embedding <=> p_query
  limit least(greatest(p_limit, 1), 50);
$$;
revoke all on function public.match_entity_embeddings(uuid, vector, int, text) from public, anon, authenticated;
grant execute on function public.match_entity_embeddings(uuid, vector, int, text) to service_role;
