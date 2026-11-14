-- LM-63: context_text for rows written before 20261112100000, for the users
-- who had already forgotten someone. Kept out of that migration so its table
-- locks are long gone: this takes row locks only, on rows that change.
--
-- Each user's entries and turns are read in key order, p_batch at a time;
-- only a row whose redacted words differ from what it holds is written. Safe
-- to run again: a second run writes nothing.

create function public._backfill_context_text(p_batch int default 1000)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid;
  v_total int := 0;
  v_n int;
  v_seen int;
  v_last_entry uuid;
  v_last_nb uuid;
  v_last_turn text;
begin
  for v_uid in
    select distinct s.user_id from public.entity_suppressions s where s.kind = 'forgotten'
  loop
    v_last_entry := '00000000-0000-0000-0000-000000000000';
    loop
      with page as (
        select je.id, public._context_text(v_uid, je.text) as c, je.context_text as held
        from public.journal_entries je
        where je.user_id = v_uid and je.id > v_last_entry
        order by je.id
        limit p_batch
      ), done as (
        update public.journal_entries je set context_text = p.c
          from page p
         where je.id = p.id and p.c is not null and p.held is distinct from p.c
        returning 1
      )
      select (select count(*) from page), (select count(*) from done),
             (select id from page order by id desc limit 1)
        into v_seen, v_n, v_last_entry;
      v_total := v_total + v_n;
      exit when v_seen < p_batch;
    end loop;

    v_last_nb := '00000000-0000-0000-0000-000000000000';
    v_last_turn := '';
    loop
      with page as (
        select ct.notebook_id, ct.turn_id, public._context_text(v_uid, ct.text) as c, ct.context_text as held
        from public.conversation_turns ct
        where ct.user_id = v_uid and (ct.notebook_id, ct.turn_id) > (v_last_nb, v_last_turn)
        order by ct.notebook_id, ct.turn_id
        limit p_batch
      ), done as (
        update public.conversation_turns ct set context_text = p.c
          from page p
         where ct.notebook_id = p.notebook_id and ct.turn_id = p.turn_id
           and p.c is not null and p.held is distinct from p.c
        returning 1
      ), last as (
        select notebook_id, turn_id from page order by notebook_id desc, turn_id desc limit 1
      )
      select (select count(*) from page), (select count(*) from done),
             (select notebook_id from last), (select turn_id from last)
        into v_seen, v_n, v_last_nb, v_last_turn;
      v_total := v_total + v_n;
      exit when v_seen < p_batch;
    end loop;
  end loop;
  return v_total;
end;
$$;

revoke all on function public._backfill_context_text(int) from public, anon, authenticated;

select public._backfill_context_text(1000);
