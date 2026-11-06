-- LM-50: remove the empty notebook row an off-the-record session leaves.
--
-- The client decides nothing here beyond asking. The server deletes only a
-- notebook the caller owns that holds no content of any kind, judged in the
-- same transaction under a row lock, so a client whose history failed to load
-- can never delete a notebook with earlier sessions. Anything else (content,
-- another user's notebook, a missing id) changes nothing and returns
-- {"deleted": false}.
--
-- Every table with a foreign key to notebooks is checked here (the pgTAP test
-- reads the catalog and fails when a new one appears without being added).

create or replace function public.delete_empty_notebook(p_notebook_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_revision bigint;
  v_title_source text;
begin
  if auth.uid() is null then
    return jsonb_build_object('deleted', false);
  end if;

  select revision, title_source into v_revision, v_title_source
    from public.notebooks
   where id = p_notebook_id and user_id = auth.uid()
     for update;
  if not found then
    return jsonb_build_object('deleted', false);
  end if;

  -- Any trace of earlier content keeps the notebook.
  if v_revision <> 0 or v_title_source <> 'auto'
     or exists (select 1 from public.conversation_turns where notebook_id = p_notebook_id)
     or exists (select 1 from public.journal_entries where notebook_id = p_notebook_id)
     or exists (select 1 from public.entities where notebook_id = p_notebook_id)
     or exists (select 1 from public.relations where notebook_id = p_notebook_id)
     or exists (select 1 from public.follow_ups where notebook_id = p_notebook_id)
     or exists (select 1 from public.asked_questions where notebook_id = p_notebook_id)
     or exists (select 1 from public.entity_embeddings where notebook_id = p_notebook_id)
     or exists (select 1 from public.notebook_commit_requests where notebook_id = p_notebook_id)
     or exists (select 1 from public.conversation_runtime_sessions where notebook_id = p_notebook_id)
     or exists (select 1 from public.session_cards where notebook_id = p_notebook_id)
     or exists (select 1 from public.session_briefs where source_notebook_id = p_notebook_id)
  then
    return jsonb_build_object('deleted', false);
  end if;

  delete from public.notebooks where id = p_notebook_id and user_id = auth.uid();
  return jsonb_build_object('deleted', true);
end;
$$;

revoke all on function public.delete_empty_notebook(uuid) from public, anon;
grant execute on function public.delete_empty_notebook(uuid) to authenticated;
