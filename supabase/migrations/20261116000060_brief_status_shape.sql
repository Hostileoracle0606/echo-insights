-- LM-102 follow-up: get_brief_status names its revision briefRevision only
-- ({status, briefRevision, currentRevision}); the cardRevision alias added in
-- 20261116000000 had no user.

create or replace function public.get_brief_status(
  p_notebook_id uuid,
  p_revision bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_current bigint;
  v_brief bigint;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'notFound', 'briefRevision', null, 'currentRevision', null);
  end if;
  select n.revision into v_current
    from public.notebooks n
    where n.id = p_notebook_id and n.user_id = v_uid;
  if not found then
    return jsonb_build_object('status', 'notFound', 'briefRevision', null, 'currentRevision', null);
  end if;
  -- One brief per user: it counts only when it is from this notebook.
  select sb.source_revision into v_brief
    from public.session_briefs sb
    where sb.user_id = v_uid and sb.source_notebook_id = p_notebook_id;
  return jsonb_build_object(
    'status', case
      when p_revision is distinct from v_current then 'stale'
      when v_brief is not distinct from p_revision then 'present'
      else 'absent' end,
    'briefRevision', v_brief,
    'currentRevision', v_current);
end;
$$;

revoke all on function public.get_brief_status(uuid, bigint) from public, anon;
grant execute on function public.get_brief_status(uuid, bigint) to authenticated;
