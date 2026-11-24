-- EC-06: every live fact of some entities, for answering exact questions in
-- code (fact-answers.ts): versions, changes, plans and totals. Ordered by
-- entity, attribute and when each was true. Retracted facts never appear.

create or replace function public.get_entity_fact_history(p_entity_ids text[])
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
    select jsonb_agg(public._memory_fact_json(f)
             order by f.entity_id, f.attribute, coalesce(f.event_at, f.stated_at), f.stated_at, f.created_at, f.id)
      from (
        select * from public.memory_facts m
         where m.user_id = v_uid and m.retracted_at is null
           and m.entity_id = any ((coalesce(p_entity_ids, '{}'::text[]))[1:20])
         limit 400
      ) f
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.get_entity_fact_history(text[]) from public, anon;
grant execute on function public.get_entity_fact_history(text[]) to authenticated;
