-- EC-03: write-time fact upserts.
--
-- After a turn is committed, the app sends the facts extraction found in it.
-- Every decision is made here, in one place, so retries and restarts are
-- safe:
--   * repeat      the value in effect at that time is the same: no new row
--   * superseded  a different value: a new row, linked to the one it replaced
--   * history     a value said now about an earlier time: stored in order,
--                 the current value is unchanged
--   * pinned      the user corrected this attribute after the statement was
--                 made (provenance user_corrected): the statement is ignored
--   * inserted    the first value, or a plan / cancellation
-- "From X to Y" (previousValue*) records Y and confirms X as the prior
-- version when X is not already the version in effect.
--
-- p_replace re-derives an edited entry: its extracted facts are deleted
-- first, corrections are kept.

create or replace function public._memory_fact_matches(
  f public.memory_facts, p_num numeric, p_text text, p_unit text
)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select (f.value_num is not distinct from p_num)
     and (lower(f.value_text) is not distinct from lower(p_text))
     and (f.unit is null or p_unit is null or lower(f.unit) = lower(p_unit));
$$;

create or replace function public.record_memory_facts(
  p_notebook_id uuid,
  p_entry_id uuid,
  p_facts jsonb,
  p_replace boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
  v_said timestamptz;
  v_item jsonb;
  v_entity text;
  v_attribute text;
  v_num numeric;
  v_text text;
  v_unit text;
  v_status text;
  v_event timestamptz;
  v_prev_num numeric;
  v_prev_text text;
  v_key timestamptz;
  v_in_effect public.memory_facts;
  v_later boolean;
  v_id uuid;
  v_outcome text;
  v_recorded jsonb := '[]'::jsonb;
  v_skipped int := 0;
begin
  if jsonb_typeof(p_facts) is distinct from 'array' then
    raise exception 'facts must be an array' using errcode = '22023';
  end if;
  select j.created_at into v_said
    from public.journal_entries j
   where j.id = p_entry_id and j.user_id = v_uid and j.notebook_id = p_notebook_id;
  if v_said is null then
    raise exception 'unknown entry' using errcode = '22023';
  end if;

  if p_replace then
    delete from public.memory_facts
     where user_id = v_uid and source_entry_id = p_entry_id and provenance = 'extracted';
  end if;

  for v_item in select value from jsonb_array_elements(p_facts) limit 20 loop
    v_entity := btrim(coalesce(v_item ->> 'entityId', ''));
    v_attribute := regexp_replace(lower(btrim(coalesce(v_item ->> 'attribute', ''))), '\s+', ' ', 'g');
    v_num := case when jsonb_typeof(v_item -> 'valueNum') = 'number' then (v_item ->> 'valueNum')::numeric end;
    v_text := left(nullif(btrim(coalesce(v_item ->> 'valueText', '')), ''), 500);
    v_unit := left(nullif(btrim(coalesce(v_item ->> 'unit', '')), ''), 40);
    v_status := coalesce(v_item ->> 'status', 'confirmed');
    v_prev_num := case when jsonb_typeof(v_item -> 'previousValueNum') = 'number'
                       then (v_item ->> 'previousValueNum')::numeric end;
    v_prev_text := left(nullif(btrim(coalesce(v_item ->> 'previousValueText', '')), ''), 500);
    begin
      v_event := (v_item ->> 'eventAt')::timestamptz;
    exception when others then
      v_event := null;
    end;

    if v_entity = '' or v_attribute = '' or length(v_attribute) > 80
       or (v_num is null and v_text is null)
       or v_status not in ('confirmed', 'proposed', 'cancelled')
       or not exists (select 1 from public.entities e where e.user_id = v_uid and e.id = v_entity) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_key := coalesce(v_event, v_said);
    v_id := null;

    -- A correction made after this was said wins.
    if exists (
      select 1 from public.memory_facts f
       where f.user_id = v_uid and f.entity_id = v_entity and f.attribute = v_attribute
         and f.retracted_at is null and f.provenance = 'user_corrected' and f.stated_at >= v_said
    ) then
      v_outcome := 'pinned';
    elsif v_status = 'confirmed' then
      select f.* into v_in_effect
        from public.memory_facts f
       where f.user_id = v_uid and f.entity_id = v_entity and f.attribute = v_attribute
         and f.retracted_at is null and f.status = 'confirmed'
         and coalesce(f.event_at, f.stated_at) <= v_key
       order by coalesce(f.event_at, f.stated_at) desc, f.stated_at desc, f.created_at desc
       limit 1;

      if v_in_effect.id is not null and public._memory_fact_matches(v_in_effect, v_num, v_text, v_unit) then
        v_outcome := 'repeat';
        v_id := v_in_effect.id;
      else
        -- "From X to Y": X is the version Y replaced.
        if (v_prev_num is not null or v_prev_text is not null)
           and (v_in_effect.id is null
                or not public._memory_fact_matches(v_in_effect, v_prev_num, v_prev_text, v_unit)) then
          insert into public.memory_facts (
            user_id, entity_id, attribute, value_num, value_text, unit, status,
            event_at, stated_at, supersedes_fact_id, source_notebook_id, source_entry_id
          ) values (
            v_uid, v_entity, v_attribute, v_prev_num, v_prev_text, v_unit, 'confirmed',
            v_event - interval '1 second', v_said - interval '1 second', v_in_effect.id,
            p_notebook_id, p_entry_id
          ) returning * into v_in_effect;
        end if;

        v_later := exists (
          select 1 from public.memory_facts f
           where f.user_id = v_uid and f.entity_id = v_entity and f.attribute = v_attribute
             and f.retracted_at is null and f.status = 'confirmed'
             and coalesce(f.event_at, f.stated_at) > v_key
        );
        insert into public.memory_facts (
          user_id, entity_id, attribute, value_num, value_text, unit, status,
          event_at, stated_at, supersedes_fact_id, source_notebook_id, source_entry_id
        ) values (
          v_uid, v_entity, v_attribute, v_num, v_text, v_unit, 'confirmed',
          v_event, v_said, v_in_effect.id, p_notebook_id, p_entry_id
        ) returning id into v_id;
        v_outcome := case when v_later then 'history'
                          when v_in_effect.id is not null then 'superseded'
                          else 'inserted' end;
      end if;
    else
      select f.id into v_id
        from public.memory_facts f
       where f.user_id = v_uid and f.entity_id = v_entity and f.attribute = v_attribute
         and f.retracted_at is null and f.status = v_status
         and public._memory_fact_matches(f, v_num, v_text, v_unit)
       limit 1;
      if v_id is not null then
        v_outcome := 'repeat';
      else
        insert into public.memory_facts (
          user_id, entity_id, attribute, value_num, value_text, unit, status,
          event_at, stated_at, source_notebook_id, source_entry_id
        ) values (
          v_uid, v_entity, v_attribute, v_num, v_text, v_unit, v_status,
          v_event, v_said, p_notebook_id, p_entry_id
        ) returning id into v_id;
        v_outcome := 'inserted';
      end if;
    end if;

    v_in_effect := null;
    v_recorded := v_recorded || jsonb_build_object(
      'factId', v_id, 'entityId', v_entity, 'attribute', v_attribute, 'outcome', v_outcome
    );
  end loop;

  return jsonb_build_object('recorded', v_recorded, 'skipped', v_skipped);
end;
$$;

-- The attribute names already in use for some entities, so extraction can
-- reuse them ("monthly savings target" lands on savings-goal.amount).
create or replace function public.list_memory_fact_keys(p_entity_ids text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('entityId', k.entity_id, 'attribute', k.attribute, 'unit', k.unit)
             order by k.entity_id, k.attribute)
      from (
        select distinct on (f.entity_id, f.attribute) f.entity_id, f.attribute, f.unit
          from public.memory_facts f
         where f.user_id = v_uid and f.retracted_at is null
           and f.entity_id = any ((coalesce(p_entity_ids, '{}'::text[]))[1:50])
         order by f.entity_id, f.attribute, f.stated_at desc
         limit 100
      ) k
  ), '[]'::jsonb);
end;
$$;

revoke all on function public._memory_fact_matches(public.memory_facts, numeric, text, text) from public, anon, authenticated;
revoke all on function public.record_memory_facts(uuid, uuid, jsonb, boolean) from public, anon;
revoke all on function public.list_memory_fact_keys(text[]) from public, anon;
grant execute on function public.record_memory_facts(uuid, uuid, jsonb, boolean) to authenticated;
grant execute on function public.list_memory_fact_keys(text[]) to authenticated;
