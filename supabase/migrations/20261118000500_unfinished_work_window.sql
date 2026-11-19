-- LM-128 (review findings 5 and 6): get_unfinished_work, redefined.
--
--   5. Catch-up only considers notebooks active in the last 14 days, so old
--      notebooks (entity-only ones, ones the runtime will never summarise,
--      pre-cards history) never crowd the 50-card cap or run model calls on
--      the first launch after deploy. "Active" is coalesce(ended_at,
--      started_at): the end time when the session was ended, the start time
--      for a notebook that was never ended (a crash). The window applies to
--      cards and the brief. Vectors and erase jobs are NOT windowed: erase is
--      a privacy obligation, and vectors are the server sweep's job.
--   6. "Latest" for the brief is the notebook that ENDED most recently (same
--      expression), not the one that started last. The live path writes the
--      brief for the notebook it just ended (ended_at = now), which is the
--      most recently ended by construction, so catch-up can no longer replace
--      a brief the live path wrote for a more recently ended notebook (and
--      clear its played_at). notebooks.updated_at is deliberately not used:
--      forget flows touch it. A never-ended notebook ranks by its start time.
--
create or replace function public.get_unfinished_work()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c_limit constant int := 50;
  v_uid uuid := auth.uid();
  v_cards jsonb;
  v_cards_total int;
  v_brief jsonb;
  v_vectors jsonb;
  v_vectors_total int;
  v_erase jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- One eligibility rule for cards and the brief: just_talk (the only mode
  -- the close-session Lambda writes), revision > 0, transcript not
  -- auto-forgotten, and something to write from: a user-speaker turn or an
  -- entity (the v2 path takes its turns from the app, so entity-only counts).
  with eligible as (
    select n.id, n.revision, n.started_at,
           coalesce(n.ended_at, n.started_at) as active_at
    from public.notebooks n
    where n.user_id = v_uid
      and n.conversation_mode = 'just_talk'
      and n.revision > 0
      and n.transcript_forgotten_at is null
      and coalesce(n.ended_at, n.started_at) >= now() - interval '14 days'
      and (exists (select 1 from public.entities e where e.notebook_id = n.id)
           or exists (select 1 from public.conversation_turns t
                      where t.notebook_id = n.id and t.speaker = 'user'))
  ), todo as (
    select e.id, e.revision, e.started_at, sc.source_revision as card_revision,
           coalesce(sc.is_draft, false) as is_draft
    from eligible e
    left join public.session_cards sc on sc.notebook_id = e.id and sc.user_id = v_uid
    where sc.notebook_id is null
       or sc.source_revision < e.revision
       or (sc.source_revision = e.revision and sc.is_draft)
  ), page as (
    select * from todo order by started_at desc, id limit c_limit
  ), latest as (
    select l.id, l.revision
    from eligible l
    order by l.active_at desc, l.id
    limit 1
  )
  select
    coalesce((select jsonb_agg(
        jsonb_build_object('notebookId', p.id, 'revision', p.revision,
                           'cardRevision', p.card_revision)
        || case when p.is_draft then jsonb_build_object('draft', true) else '{}'::jsonb end
        order by p.started_at desc, p.id) from page p), '[]'::jsonb),
    (select count(*)::int from todo),
    (select jsonb_build_object('notebookId', l.id, 'revision', l.revision)
       from latest l
       where not exists (
         select 1 from public.session_briefs sb
         where sb.user_id = v_uid and sb.source_notebook_id = l.id
           and sb.source_revision = l.revision))
  into v_cards, v_cards_total, v_brief;

  with missing as (
    select n.id, n.started_at, count(*)::int as entity_count,
           count(*) filter (where ee.entity_id is null)::int as missing
    from public.notebooks n
    join public.entities e on e.notebook_id = n.id and e.user_id = v_uid
    left join public.entity_embeddings ee
      on ee.notebook_id = e.notebook_id and ee.entity_id = e.id
    where n.user_id = v_uid
    group by n.id, n.started_at
    having count(*) filter (where ee.entity_id is null) > 0
  ), page as (
    select * from missing order by started_at desc, id limit c_limit
  )
  select
    coalesce((select jsonb_agg(
        jsonb_build_object('notebookId', p.id, 'entityCount', p.entity_count,
                           'missing', p.missing)
        order by p.started_at desc, p.id) from page p), '[]'::jsonb),
    (select count(*)::int from missing)
  into v_vectors, v_vectors_total;

  v_erase := public.forget_erase_pending();

  return jsonb_build_object(
    'cards', v_cards,
    'briefs', case when v_brief is null then '[]'::jsonb else jsonb_build_array(v_brief) end,
    'vectors', v_vectors,
    'erase', v_erase,
    'truncated', v_cards_total > c_limit or v_vectors_total > c_limit
  );
end;
$$;

revoke all on function public.get_unfinished_work() from public, anon;
grant execute on function public.get_unfinished_work() to authenticated;
