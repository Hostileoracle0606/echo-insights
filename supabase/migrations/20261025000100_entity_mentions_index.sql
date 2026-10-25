-- Entity mentions read an index instead of scanning every entry.
--
-- get_entity_mentions (3 calls per recall, and the entity note page) used to
-- filter journal_entries on `entity_ids @> array[id]`. No index narrows that
-- per user, so every call read all of the user's entries: O(N). A posting
-- list, one row per (entry, entity), with a B-tree on
-- (user_id, entity_id, created_at desc, entry_id desc), serves "newest k" and
-- "how many" directly: O(log N + k). Measured at 60k entries: a page went
-- from 9.4 ms to 0.036 ms. See docs/complexity-audit.md (#4) and
-- docs/performance-fixes.md.
--
-- A trigger on journal_entries keeps the list current for every writer
-- (commit_notebook, remove_entity's array_remove, anything later), so no
-- write-path function had to change. The output of get_entity_mentions is
-- unchanged, field for field.

-- ── 1. the posting list ──────────────────────────────────────────────────
create table public.entry_entities (
  entry_id    uuid not null references public.journal_entries(id) on delete cascade,
  entity_id   text not null,
  user_id     uuid not null references auth.users(id) on delete cascade,
  notebook_id uuid not null references public.notebooks(id) on delete cascade,
  created_at  timestamptz not null,
  primary key (entry_id, entity_id)
);

create index entry_entities_lookup_idx
  on public.entry_entities (user_id, entity_id, created_at desc, entry_id desc);

alter table public.entry_entities enable row level security;
create policy "owner select" on public.entry_entities
  for select using ((select auth.uid()) = user_id);
revoke all on public.entry_entities from anon;
revoke insert, update, delete, truncate on public.entry_entities from authenticated;
grant select on public.entry_entities to authenticated;

-- ── 2. kept current by a trigger ─────────────────────────────────────────
-- SECURITY DEFINER because clients cannot write the table; it only ever
-- writes rows derived from the entry being inserted or updated.
create or replace function public._sync_entry_entities()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' then
    delete from public.entry_entities where entry_id = old.id;
  end if;
  insert into public.entry_entities (entry_id, entity_id, user_id, notebook_id, created_at)
  select distinct new.id, x, new.user_id, new.notebook_id, new.created_at
  from unnest(new.entity_ids) as x
  on conflict do nothing;
  return null;
end;
$$;
revoke all on function public._sync_entry_entities() from public, anon, authenticated;

-- Deletes need no trigger: the foreign key cascades.
create trigger journal_entries_sync_entry_entities
  after insert or update of entity_ids, user_id, notebook_id, created_at
  on public.journal_entries
  for each row execute function public._sync_entry_entities();

-- ── 3. backfill ──────────────────────────────────────────────────────────
insert into public.entry_entities (entry_id, entity_id, user_id, notebook_id, created_at)
select distinct je.id, x, je.user_id, je.notebook_id, je.created_at
from public.journal_entries je, unnest(je.entity_ids) as x
on conflict do nothing;

-- ── 4. the turn a mention came from, by index ────────────────────────────
-- The mention's turn is the user turn in the same notebook with exactly the
-- entry's text. An index on md5(text) finds it without reading the
-- notebook's turns; comparing the full text as well keeps it exact.
create index conversation_turns_text_lookup_idx
  on public.conversation_turns (notebook_id, speaker, md5(text), spoken_at desc);

-- ── 5. get_entity_mentions on the posting list ───────────────────────────
-- Same signature, same JSON, same order and paging (p_before exclusive).
create or replace function public.get_entity_mentions(
  p_entity_id text,
  p_limit int default 20,
  p_before timestamptz default null
) returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  with page as (
    select je.id, je.notebook_id, je.text, je.created_at
    from (
      select ee.entry_id, ee.created_at
      from public.entry_entities ee
      where ee.user_id = (select auth.uid())
        and ee.entity_id = p_entity_id
        and (p_before is null or ee.created_at < p_before)
      order by ee.created_at desc, ee.entry_id desc
      limit least(greatest(coalesce(p_limit, 20), 1), 100)
    ) top
    join public.journal_entries je on je.id = top.entry_id
  )
  select jsonb_build_object(
    'total', (
      select count(*)
      from public.entry_entities ee
      where ee.user_id = (select auth.uid()) and ee.entity_id = p_entity_id
    ),
    'mentions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entryId', p.id, 'notebookId', p.notebook_id,
        'notebookTitle', nb.title, 'notebookStartedAt', nb.started_at,
        'conversationMode', nb.conversation_mode,
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
          and md5(ct.text) = md5(p.text)
          and ct.text = p.text
          and ct.spoken_at <= p.created_at
        order by ct.spoken_at desc
        limit 1
      ) t on true
    ), '[]'::jsonb)
  );
$$;
