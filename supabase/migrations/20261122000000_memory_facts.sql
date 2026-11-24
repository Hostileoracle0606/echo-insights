-- EC-02: the fact layer.
--
-- A fact is one typed value of an entity's attribute: "savings-goal.amount =
-- 8000 USD, confirmed, said 20 Nov". Facts are extracted once, when the user
-- speaks (EC-03), so answering a direct question is a query, not a model call
-- (EC-06).
--
-- Two ways a value stops being current, kept distinct:
--   * supersede: a real-world change ("raised it to 8k"). The old row stays
--     and is history.
--   * retract: a correction ("I never said 8k"). The wrong row is hidden from
--     every read, history included. Corrections are pinned (provenance
--     user_corrected) so re-extraction never overwrites them (EC-07).
--
-- Facts hang off the user's entities by slug (entities are stored per
-- notebook; the same slug is the same entity across notebooks, as in
-- get_user_graph). Reads are owner-only and never show retracted rows; writes
-- go through security-definer RPCs only.

create table public.memory_facts (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  entity_id          text not null check (length(entity_id) between 1 and 200),
  attribute          text not null check (attribute = lower(btrim(attribute)) and length(attribute) between 1 and 80),
  value_num          numeric,
  value_text         text check (value_text is null or length(value_text) between 1 and 500),
  unit               text check (unit is null or length(unit) <= 40),
  status             text not null check (status in ('confirmed', 'proposed', 'cancelled')),
  event_at           timestamptz,
  stated_at          timestamptz not null,
  supersedes_fact_id uuid references public.memory_facts(id) on delete set null,
  retracted_at       timestamptz,
  retraction_reason  text check (retraction_reason in ('corrected', 'user_removed')),
  provenance         text not null default 'extracted' check (provenance in ('extracted', 'user_corrected')),
  source_notebook_id uuid references public.notebooks(id) on delete cascade,
  source_entry_id    uuid references public.journal_entries(id) on delete cascade,
  created_at         timestamptz not null default now(),
  check (value_num is not null or value_text is not null),
  check ((retracted_at is null) = (retraction_reason is null))
);

-- Every read is "the versions of one entity attribute, in the order they were
-- true": current, previous, as of, history are each one index range scan.
create index memory_facts_version_idx on public.memory_facts
  (user_id, entity_id, attribute, (coalesce(event_at, stated_at)) desc, stated_at desc)
  where retracted_at is null;
create index memory_facts_source_entry_idx on public.memory_facts (source_entry_id)
  where source_entry_id is not null;

alter table public.memory_facts enable row level security;

-- Owner reads only, and a retracted fact is invisible even to its owner.
create policy "owner select live" on public.memory_facts
  for select using (auth.uid() = user_id and retracted_at is null);

revoke all on table public.memory_facts from public, anon;
revoke insert, update, delete on table public.memory_facts from authenticated;
grant select on table public.memory_facts to authenticated;

-- ── helpers ────────────────────────────────────────────────────────────────

create or replace function public._memory_fact_json(f public.memory_facts)
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', f.id,
    'entityId', f.entity_id,
    'attribute', f.attribute,
    'valueNum', f.value_num,
    'valueText', f.value_text,
    'unit', f.unit,
    'status', f.status,
    'eventAt', f.event_at,
    'statedAt', f.stated_at,
    'supersedesFactId', f.supersedes_fact_id,
    'provenance', f.provenance,
    'sourceNotebookId', f.source_notebook_id,
    'sourceEntryId', f.source_entry_id
  );
$$;

create or replace function public._memory_fact_uid()
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  return auth.uid();
end;
$$;

-- ── write ──────────────────────────────────────────────────────────────────

create or replace function public.insert_memory_fact(p_fact jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
  v_entity text := btrim(coalesce(p_fact ->> 'entityId', ''));
  v_attribute text := lower(btrim(coalesce(p_fact ->> 'attribute', '')));
  v_num numeric;
  v_text text := nullif(btrim(coalesce(p_fact ->> 'valueText', '')), '');
  v_unit text := nullif(btrim(coalesce(p_fact ->> 'unit', '')), '');
  v_status text := p_fact ->> 'status';
  v_provenance text := coalesce(p_fact ->> 'provenance', 'extracted');
  v_event timestamptz;
  v_stated timestamptz;
  v_supersedes uuid;
  v_notebook uuid;
  v_entry uuid;
  v_id uuid;
begin
  if jsonb_typeof(p_fact) is distinct from 'object' then
    raise exception 'fact must be an object' using errcode = '22023';
  end if;
  if v_entity = '' or v_attribute = '' or length(v_attribute) > 80 then
    raise exception 'entityId and attribute are required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.entities e where e.user_id = v_uid and e.id = v_entity) then
    raise exception 'unknown entity' using errcode = '22023';
  end if;
  if p_fact ? 'valueNum' and jsonb_typeof(p_fact -> 'valueNum') <> 'null' then
    if jsonb_typeof(p_fact -> 'valueNum') <> 'number' then
      raise exception 'valueNum must be a number' using errcode = '22023';
    end if;
    v_num := (p_fact ->> 'valueNum')::numeric;
  end if;
  if v_num is null and v_text is null then
    raise exception 'a fact needs a value' using errcode = '22023';
  end if;
  if v_status is null or v_status not in ('confirmed', 'proposed', 'cancelled') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  if v_provenance not in ('extracted', 'user_corrected') then
    raise exception 'invalid provenance' using errcode = '22023';
  end if;
  begin
    v_stated := (p_fact ->> 'statedAt')::timestamptz;
    v_event := (p_fact ->> 'eventAt')::timestamptz;
    v_supersedes := (p_fact ->> 'supersedesFactId')::uuid;
    v_notebook := (p_fact ->> 'sourceNotebookId')::uuid;
    v_entry := (p_fact ->> 'sourceEntryId')::uuid;
  exception when others then
    raise exception 'invalid date or id' using errcode = '22023';
  end;
  if v_stated is null then
    raise exception 'statedAt is required' using errcode = '22023';
  end if;
  if v_supersedes is not null and not exists (
    select 1 from public.memory_facts f
    where f.id = v_supersedes and f.user_id = v_uid and f.retracted_at is null
      and f.entity_id = v_entity and f.attribute = v_attribute
  ) then
    raise exception 'unknown superseded fact' using errcode = '22023';
  end if;
  if v_notebook is not null and not exists (
    select 1 from public.notebooks n where n.id = v_notebook and n.user_id = v_uid
  ) then
    raise exception 'unknown notebook' using errcode = '22023';
  end if;
  if v_entry is not null and not exists (
    select 1 from public.journal_entries j
    where j.id = v_entry and j.user_id = v_uid
      and (v_notebook is null or j.notebook_id = v_notebook)
  ) then
    raise exception 'unknown entry' using errcode = '22023';
  end if;

  insert into public.memory_facts (
    user_id, entity_id, attribute, value_num, value_text, unit, status,
    event_at, stated_at, supersedes_fact_id, provenance, source_notebook_id, source_entry_id
  ) values (
    v_uid, v_entity, v_attribute, v_num, left(v_text, 500), left(v_unit, 40), v_status,
    v_event, v_stated, v_supersedes, v_provenance, v_notebook, v_entry
  ) returning id into v_id;
  return v_id;
end;
$$;

-- A correction or removal: the fact disappears from every read. Returns false
-- when the caller has no such live fact.
create or replace function public.retract_memory_fact(p_fact_id uuid, p_reason text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
begin
  if p_reason is null or p_reason not in ('corrected', 'user_removed') then
    raise exception 'invalid retraction reason' using errcode = '22023';
  end if;
  update public.memory_facts
     set retracted_at = now(), retraction_reason = p_reason
   where id = p_fact_id and user_id = v_uid and retracted_at is null;
  return found;
end;
$$;

-- ── read ───────────────────────────────────────────────────────────────────

-- The confirmed value of one entity attribute: 'current' (latest), 'previous'
-- (the one before it) or 'as_of' (in effect at p_at). Versions are ordered by
-- when they were true (event_at, else when said). Plans and cancelled events
-- are not values; see get_memory_fact_history for those.
create or replace function public.get_memory_fact(
  p_entity_id text,
  p_attribute text,
  p_scope text default 'current',
  p_at timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
  v_attribute text := lower(btrim(coalesce(p_attribute, '')));
  v_fact public.memory_facts;
begin
  if p_scope not in ('current', 'previous', 'as_of') then
    raise exception 'invalid scope' using errcode = '22023';
  end if;
  if p_scope = 'as_of' and p_at is null then
    raise exception 'as_of needs a time' using errcode = '22023';
  end if;
  select f.* into v_fact
    from public.memory_facts f
   where f.user_id = v_uid and f.entity_id = p_entity_id and f.attribute = v_attribute
     and f.retracted_at is null and f.status = 'confirmed'
     and (p_scope <> 'as_of' or coalesce(f.event_at, f.stated_at) <= p_at)
   order by coalesce(f.event_at, f.stated_at) desc, f.stated_at desc, f.created_at desc, f.id
   offset case when p_scope = 'previous' then 1 else 0 end
   limit 1;
  return jsonb_build_object(
    'fact', case when v_fact.id is null then null else public._memory_fact_json(v_fact) end
  );
end;
$$;

-- Every live version of one entity attribute, oldest first, with plans and
-- cancellations. Retracted facts are never included.
create or replace function public.get_memory_fact_history(p_entity_id text, p_attribute text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
begin
  return jsonb_build_object('facts', coalesce((
    select jsonb_agg(public._memory_fact_json(f)
             order by coalesce(f.event_at, f.stated_at), f.stated_at, f.created_at, f.id)
      from public.memory_facts f
     where f.user_id = v_uid and f.entity_id = p_entity_id
       and f.attribute = lower(btrim(coalesce(p_attribute, '')))
       and f.retracted_at is null
  ), '[]'::jsonb));
end;
$$;

revoke all on function public._memory_fact_json(public.memory_facts) from public, anon, authenticated;
revoke all on function public._memory_fact_uid() from public, anon, authenticated;
revoke all on function public.insert_memory_fact(jsonb) from public, anon;
revoke all on function public.retract_memory_fact(uuid, text) from public, anon;
revoke all on function public.get_memory_fact(text, text, text, timestamptz) from public, anon;
revoke all on function public.get_memory_fact_history(text, text) from public, anon;
grant execute on function public.insert_memory_fact(jsonb) to authenticated;
grant execute on function public.retract_memory_fact(uuid, text) to authenticated;
grant execute on function public.get_memory_fact(text, text, text, timestamptz) to authenticated;
grant execute on function public.get_memory_fact_history(text, text) to authenticated;
