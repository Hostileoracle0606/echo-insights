-- The user-wide entity view reads a maintained table instead of
-- re-aggregating every call.
--
-- user_entities (LM-06) grouped all of a user's entity rows on every read:
-- O(M log M) for M rows across notebooks, 28 ms at 3,000 rows, on every
-- recall and the Memory screen. Commits are one per turn while reads happen
-- on every recall, so the aggregate is now kept per (user_id, id) in
-- user_entity_stats and refreshed for exactly the slugs a write touches.
-- user_entities keeps its name, columns and meaning, so get_user_graph and
-- every other reader are unchanged. See docs/complexity-audit.md (#8) and
-- docs/performance-fixes.md.

-- ── 1. the table, one row per (user_id, id) ─────────────────────────────
create table public.user_entity_stats (
  user_id        uuid not null references auth.users(id) on delete cascade,
  id             text not null,
  name           text not null,
  type           text not null,
  description    text,
  mentions       int not null,
  first_seen     timestamptz not null,
  last_seen      timestamptz not null,
  notebook_ids   uuid[] not null,
  notebook_count int not null,
  primary key (user_id, id)
);

-- get_user_graph orders by (mentions desc, last_seen desc, id) per user.
create index user_entity_stats_rank_idx
  on public.user_entity_stats (user_id, mentions desc, last_seen desc, id);

alter table public.user_entity_stats enable row level security;
create policy "owner select" on public.user_entity_stats
  for select using ((select auth.uid()) = user_id);
revoke all on public.user_entity_stats from anon;
revoke insert, update, delete, truncate on public.user_entity_stats from authenticated;
grant select on public.user_entity_stats to authenticated;

-- ── 2. recompute one slug, with exactly the view's old rules ────────────
create or replace function public._refresh_user_entity(p_user_id uuid, p_id text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.user_entity_stats where user_id = p_user_id and id = p_id;
  insert into public.user_entity_stats
    (user_id, id, name, type, description, mentions, first_seen, last_seen, notebook_ids, notebook_count)
  select
    e.user_id,
    e.id,
    (array_agg(e.name order by e.last_seen desc, e.notebook_id))[1],
    (array_agg(e.type order by e.last_seen desc, e.notebook_id))[1],
    (array_agg(e.description order by e.last_seen desc, e.notebook_id)
       filter (where e.description is not null))[1],
    sum(e.mentions)::int,
    min(e.first_seen),
    max(e.last_seen),
    array_agg(e.notebook_id order by e.first_seen, e.notebook_id),
    count(*)::int
  from public.entities e
  where e.user_id = p_user_id and e.id = p_id
  group by e.user_id, e.id;
end;
$$;
revoke all on function public._refresh_user_entity(uuid, text) from public, anon, authenticated;

create or replace function public._sync_user_entity_stats()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public._refresh_user_entity(old.user_id, old.id);
  end if;
  if tg_op in ('INSERT', 'UPDATE')
     and (tg_op = 'INSERT' or new.user_id is distinct from old.user_id or new.id is distinct from old.id) then
    perform public._refresh_user_entity(new.user_id, new.id);
  end if;
  return null;
end;
$$;
revoke all on function public._sync_user_entity_stats() from public, anon, authenticated;

-- Only the columns the aggregate reads; metadata, questions and
-- description_source updates skip the refresh.
create trigger entities_sync_user_entity_stats
  after insert or delete
     or update of id, user_id, notebook_id, name, type, description, mentions, first_seen, last_seen
  on public.entities
  for each row execute function public._sync_user_entity_stats();

-- ── 3. backfill ──────────────────────────────────────────────────────────
insert into public.user_entity_stats
  (user_id, id, name, type, description, mentions, first_seen, last_seen, notebook_ids, notebook_count)
select
  e.user_id,
  e.id,
  (array_agg(e.name order by e.last_seen desc, e.notebook_id))[1],
  (array_agg(e.type order by e.last_seen desc, e.notebook_id))[1],
  (array_agg(e.description order by e.last_seen desc, e.notebook_id)
     filter (where e.description is not null))[1],
  sum(e.mentions)::int,
  min(e.first_seen),
  max(e.last_seen),
  array_agg(e.notebook_id order by e.first_seen, e.notebook_id),
  count(*)::int
from public.entities e
group by e.user_id, e.id;

-- ── 4. the view now reads the table ──────────────────────────────────────
-- Same columns in the same order, so CREATE OR REPLACE keeps every grant
-- and every dependent function working.
create or replace view public.user_entities with (security_invoker = true) as
select user_id, id, name, type, description, mentions, first_seen, last_seen,
       notebook_ids, notebook_count
from public.user_entity_stats;
