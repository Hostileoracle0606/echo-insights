-- EC-07: the correction flow.
--
-- propose_memory_correction finds the fact the user is disputing (by the
-- thing's name and, when needed, the attribute), stores a pending correction
-- and returns a read-back sentence built here, in code. Nothing changes
-- until apply_memory_correction, which Lumen calls only after the user says
-- yes. A confirmed change retracts the wrong fact (never shown again, not even
-- as history) and stores the right one pinned (provenance user_corrected), so
-- re-extraction cannot overwrite it. A confirmed removal retracts with
-- reason user_removed. reject_memory_correction records a "no"; after two
-- rejected read-backs for one fact the caller offers to remove it instead.

create table public.memory_fact_corrections (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  fact_id     uuid not null references public.memory_facts(id) on delete cascade,
  change      jsonb not null,
  read_back   text not null,
  status      text not null default 'pending' check (status in ('pending', 'applied', 'rejected', 'expired')),
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);

create index memory_fact_corrections_fact_idx on public.memory_fact_corrections (fact_id, status);

alter table public.memory_fact_corrections enable row level security;
create policy "owner select" on public.memory_fact_corrections
  for select using (auth.uid() = user_id);
revoke all on table public.memory_fact_corrections from public, anon;
revoke insert, update, delete on table public.memory_fact_corrections from authenticated;
grant select on table public.memory_fact_corrections to authenticated;

-- "8000 USD", "the 1st".
create or replace function public._memory_fact_value(p_num numeric, p_text text, p_unit text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(trim_scale(p_num)::text, p_text) || coalesce(' ' || p_unit, '');
$$;

create or replace function public._memory_day(p_at timestamptz)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select to_char(p_at at time zone 'UTC', 'FMDD Mon YYYY');
$$;

-- The user's entity a spoken name refers to: exact name, then id, then a
-- name containing it. Null when nothing fits.
create or replace function public._memory_entity(p_uid uuid, p_about text)
returns table (id text, name text)
language sql
stable
set search_path = public, pg_temp
as $$
  select e.id, e.name
    from public.entities e
   where e.user_id = p_uid
     and (lower(e.name) = lower(btrim(p_about))
          or e.id = lower(regexp_replace(btrim(p_about), '[^A-Za-z0-9]+', '-', 'g'))
          or lower(e.name) like '%' || lower(btrim(p_about)) || '%')
   order by (lower(e.name) = lower(btrim(p_about))) desc,
            (e.id = lower(regexp_replace(btrim(p_about), '[^A-Za-z0-9]+', '-', 'g'))) desc,
            length(e.name), e.id
   limit 1;
$$;

create or replace function public.propose_memory_correction(
  p_about text,
  p_attribute text,
  p_change jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
  v_entity record;
  v_target record;
  v_attribute text;
  v_keys text[];
  v_fact public.memory_facts;
  v_label text;
  v_old text;
  v_new text;
  v_read text;
  v_id uuid;
  v_num numeric;
  v_status text;
  v_event timestamptz;
begin
  if jsonb_typeof(p_change) is distinct from 'object'
     or not (p_change ?| array['valueNum', 'valueText', 'unit', 'status', 'eventAt', 'entity', 'remove']) then
    raise exception 'a correction must change something' using errcode = '22023';
  end if;
  v_status := p_change ->> 'status';
  if v_status is not null and v_status not in ('confirmed', 'proposed', 'cancelled') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  if p_change ? 'valueNum' then
    if jsonb_typeof(p_change -> 'valueNum') <> 'number' then
      raise exception 'valueNum must be a number' using errcode = '22023';
    end if;
    v_num := (p_change ->> 'valueNum')::numeric;
  end if;
  if p_change ? 'eventAt' then
    begin
      v_event := (p_change ->> 'eventAt')::timestamptz;
    exception when others then
      raise exception 'invalid eventAt' using errcode = '22023';
    end;
  end if;

  select * into v_entity from public._memory_entity(v_uid, coalesce(p_about, ''));
  if v_entity.id is null then
    return jsonb_build_object('status', 'not_found');
  end if;

  v_attribute := nullif(regexp_replace(lower(btrim(coalesce(p_attribute, ''))), '\s+', ' ', 'g'), '');
  select array_agg(distinct f.attribute order by f.attribute) into v_keys
    from public.memory_facts f
   where f.user_id = v_uid and f.entity_id = v_entity.id and f.retracted_at is null
     and (v_attribute is null
          or f.attribute = v_attribute
          or replace(f.attribute, '_', ' ') = replace(v_attribute, '_', ' '));
  if v_keys is null then
    return jsonb_build_object('status', 'not_found');
  end if;
  if array_length(v_keys, 1) > 1 then
    return jsonb_build_object('status', 'ask', 'question',
      'Which do you mean: ' || array_to_string(
        array(select v_entity.name || ' ' || replace(k, '_', ' ') from unnest(v_keys) k), ' or ') || '?');
  end if;

  -- The value being disputed: the current confirmed one, else the latest said.
  select f.* into v_fact
    from public.memory_facts f
   where f.user_id = v_uid and f.entity_id = v_entity.id and f.attribute = v_keys[1]
     and f.retracted_at is null
   order by (f.status = 'confirmed') desc, coalesce(f.event_at, f.stated_at) desc, f.stated_at desc
   limit 1;

  v_label := v_entity.name || ' ' || replace(v_fact.attribute, '_', ' ');
  v_old := public._memory_fact_value(v_fact.value_num, v_fact.value_text, v_fact.unit);

  if coalesce((p_change ->> 'remove')::boolean, false) then
    v_read := 'So I should forget that your ' || v_label || ' is ' || v_old || '. Is that right?';
  elsif p_change ? 'entity' then
    select * into v_target from public._memory_entity(v_uid, p_change ->> 'entity');
    if v_target.id is null or v_target.id = v_entity.id then
      return jsonb_build_object('status', 'not_found');
    end if;
    p_change := p_change || jsonb_build_object('entityId', v_target.id);
    v_read := 'So it was ' || v_target.name || '''s ' || replace(v_fact.attribute, '_', ' ') || ' that is ' || v_old ||
              ', not your ' || v_entity.name || '''s. Is that right?';
  elsif v_status is not null and not (p_change ?| array['valueNum', 'valueText', 'eventAt']) then
    v_read := 'So your ' || v_label || ' ' || v_old || case v_status
      when 'proposed' then ' was only planned, not done.'
      when 'cancelled' then ' was called off.'
      else ' did happen.' end || ' Is that right?';
  elsif v_event is not null and not (p_change ?| array['valueNum', 'valueText']) then
    v_read := 'So your ' || v_label || ' of ' || v_old || ' was on ' || public._memory_day(v_event) ||
              ', not ' || public._memory_day(coalesce(v_fact.event_at, v_fact.stated_at)) || '. Is that right?';
  else
    v_new := public._memory_fact_value(
      coalesce(v_num, case when p_change ? 'valueText' then null else v_fact.value_num end),
      coalesce(nullif(btrim(p_change ->> 'valueText'), ''), case when p_change ? 'valueNum' then null else v_fact.value_text end),
      coalesce(nullif(btrim(p_change ->> 'unit'), ''), v_fact.unit));
    if v_new is null then
      raise exception 'a correction must change something' using errcode = '22023';
    end if;
    v_read := 'So your ' || v_label || ' is ' || v_new || ', not ' || v_old || '. Is that right?';
  end if;

  insert into public.memory_fact_corrections (user_id, fact_id, change, read_back)
  values (v_uid, v_fact.id, p_change, v_read)
  returning id into v_id;
  return jsonb_build_object('status', 'pending', 'correctionId', v_id, 'readBack', v_read);
end;
$$;

create or replace function public.apply_memory_correction(p_correction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
  v_c public.memory_fact_corrections;
  v_fact public.memory_facts;
  v_change jsonb;
  v_id uuid;
begin
  select * into v_c from public.memory_fact_corrections
   where id = p_correction_id and user_id = v_uid and status = 'pending'
   for update;
  if v_c.id is null then
    return jsonb_build_object('status', 'not_pending');
  end if;
  select * into v_fact from public.memory_facts
   where id = v_c.fact_id and user_id = v_uid and retracted_at is null;
  if v_fact.id is null then
    update public.memory_fact_corrections set status = 'expired', resolved_at = now() where id = v_c.id;
    return jsonb_build_object('status', 'not_pending');
  end if;
  v_change := v_c.change;

  if coalesce((v_change ->> 'remove')::boolean, false) then
    update public.memory_facts set retracted_at = now(), retraction_reason = 'user_removed' where id = v_fact.id;
  else
    update public.memory_facts set retracted_at = now(), retraction_reason = 'corrected' where id = v_fact.id;
    insert into public.memory_facts (
      user_id, entity_id, attribute, value_num, value_text, unit, status,
      event_at, stated_at, provenance, source_notebook_id, source_entry_id
    ) values (
      v_uid,
      coalesce(v_change ->> 'entityId', v_fact.entity_id),
      v_fact.attribute,
      case when v_change ? 'valueNum' then (v_change ->> 'valueNum')::numeric
           when v_change ? 'valueText' then null else v_fact.value_num end,
      case when v_change ? 'valueText' then nullif(btrim(v_change ->> 'valueText'), '')
           when v_change ? 'valueNum' then null else v_fact.value_text end,
      coalesce(nullif(btrim(v_change ->> 'unit'), ''), v_fact.unit),
      coalesce(v_change ->> 'status', v_fact.status),
      case when v_change ? 'eventAt' then (v_change ->> 'eventAt')::timestamptz else v_fact.event_at end,
      now(),
      'user_corrected',
      v_fact.source_notebook_id,
      v_fact.source_entry_id
    ) returning id into v_id;
  end if;

  update public.memory_fact_corrections set status = 'applied', resolved_at = now() where id = v_c.id;
  return jsonb_build_object('status', 'applied', 'factId', v_id);
end;
$$;

create or replace function public.reject_memory_correction(p_correction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
  v_fact uuid;
  v_rejected int;
begin
  update public.memory_fact_corrections set status = 'rejected', resolved_at = now()
   where id = p_correction_id and user_id = v_uid and status = 'pending'
  returning fact_id into v_fact;
  if v_fact is null then
    return jsonb_build_object('status', 'not_pending');
  end if;
  select count(*) into v_rejected from public.memory_fact_corrections
   where user_id = v_uid and fact_id = v_fact and status = 'rejected';
  return jsonb_build_object('status', 'rejected', 'offerRemoval', v_rejected >= 2);
end;
$$;

revoke all on function public._memory_fact_value(numeric, text, text) from public, anon, authenticated;
revoke all on function public._memory_day(timestamptz) from public, anon, authenticated;
revoke all on function public._memory_entity(uuid, text) from public, anon, authenticated;
revoke all on function public.propose_memory_correction(text, text, jsonb) from public, anon;
revoke all on function public.apply_memory_correction(uuid) from public, anon;
revoke all on function public.reject_memory_correction(uuid) from public, anon;
grant execute on function public.propose_memory_correction(text, text, jsonb) to authenticated;
grant execute on function public.apply_memory_correction(uuid) to authenticated;
grant execute on function public.reject_memory_correction(uuid) to authenticated;
