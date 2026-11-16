-- LM-103: one owner-scoped, read-only list of the text steps the phone should
-- finish at launch. Ids and numbers only: no title, summary, card, brief or
-- entity text is ever returned.
--
--   cards   notebooks the close-session Lambda would write a card for (only
--           just_talk, revision > 0, content present as an entity or a turn,
--           transcript not auto-forgotten) whose card is absent or older than
--           revision, or is a draft at the current revision (a draft is not a
--           finished card). cardRevision is null when no card exists; `draft`
--           is added only for a draft row.
--   briefs  briefs are one per user and only from just_talk: the latest
--           eligible just_talk notebook, if its brief is not at its revision.
--   vectors notebooks with entities that have no entity_embeddings row.
--           Counts missing rows only. A row whose content_hash or
--           embedding_model is stale needs a SHA-256 and the model id, which
--           SQL cannot cheaply compute: that is left to embed-reconcile (the
--           15 minute sweep), which does the precise check.
--   erase   forget_erase_jobs, as forget_erase_pending() reports them.
--
-- Each notebook list holds at most 50 rows, newest first; `truncated` is true
-- when any list had more.

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

  with eligible as (
    select n.id, n.revision, n.started_at
    from public.notebooks n
    where n.user_id = v_uid
      and n.conversation_mode = 'just_talk'
      and n.revision > 0
      and n.transcript_forgotten_at is null
      and (exists (select 1 from public.entities e where e.notebook_id = n.id)
           or exists (select 1 from public.conversation_turns t where t.notebook_id = n.id))
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
  )
  select
    coalesce((select jsonb_agg(
        jsonb_build_object('notebookId', p.id, 'revision', p.revision,
                           'cardRevision', p.card_revision)
        || case when p.is_draft then jsonb_build_object('draft', true) else '{}'::jsonb end
        order by p.started_at desc, p.id) from page p), '[]'::jsonb),
    (select count(*)::int from todo)
  into v_cards, v_cards_total;

  select jsonb_build_object('notebookId', l.id, 'revision', l.revision)
    into v_brief
    from (
      select n.id, n.revision
      from public.notebooks n
      where n.user_id = v_uid
        and n.conversation_mode = 'just_talk'
        and n.revision > 0
        and n.transcript_forgotten_at is null
        and (exists (select 1 from public.entities e where e.notebook_id = n.id)
             or exists (select 1 from public.conversation_turns t where t.notebook_id = n.id))
      order by n.started_at desc, n.id
      limit 1
    ) l
    where not exists (
      select 1 from public.session_briefs sb
      where sb.user_id = v_uid and sb.source_notebook_id = l.id
        and sb.source_revision = l.revision);

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
