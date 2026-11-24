-- EC-05: the facts of the rebuilt context's working set.
--
-- For each entity attribute asked about: its current confirmed value, plus
-- any plan or cancellation said after that value. One row per value, so the
-- context never carries two versions of one fact. Retracted facts are never
-- returned (memory_facts reads exclude them everywhere).

create or replace function public.get_current_facts(p_entity_ids text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._memory_fact_uid();
  v_ids text[] := (coalesce(p_entity_ids, '{}'::text[]))[1:60];
begin
  return coalesce((
    with live as (
      select f.*
        from public.memory_facts f
       where f.user_id = v_uid and f.retracted_at is null and f.entity_id = any (v_ids)
    ),
    current_value as (
      select distinct on (l.entity_id, l.attribute) l.*
        from live l
       where l.status = 'confirmed'
       order by l.entity_id, l.attribute,
                coalesce(l.event_at, l.stated_at) desc, l.stated_at desc, l.created_at desc
    ),
    later_plans as (
      select distinct on (l.entity_id, l.attribute, l.status) l.*
        from live l
        left join current_value c on c.entity_id = l.entity_id and c.attribute = l.attribute
       where l.status <> 'confirmed' and (c.id is null or l.stated_at > c.stated_at)
       order by l.entity_id, l.attribute, l.status, l.stated_at desc
    )
    select jsonb_agg(public._memory_fact_json(x) order by x.entity_id, x.attribute, x.status, x.id)
      from (select * from current_value union all select * from later_plans) x
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.get_current_facts(text[]) from public, anon;
grant execute on function public.get_current_facts(text[]) to authenticated;
