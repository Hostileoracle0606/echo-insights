-- The fact layer (EC-02..EC-08) added memory_facts, memory_fact_corrections,
-- conversation_state and memory_backfill_progress. All cascade from
-- auth.users, so account deletion already removes them; this makes
-- delete_empty_notebook treat a notebook's facts or saved session state as
-- content (a trace of earlier use), like its other per-notebook tables.

create or replace function public.delete_empty_notebook(p_notebook_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_revision bigint;
  v_title_source text;
  v_transcript_forgotten_at timestamptz;
begin
  if auth.uid() is null then
    return jsonb_build_object('deleted', false);
  end if;

  select revision, title_source, transcript_forgotten_at
      into v_revision, v_title_source, v_transcript_forgotten_at
    from public.notebooks
   where id = p_notebook_id and user_id = auth.uid()
     for update;
  if not found then
    return jsonb_build_object('deleted', false);
  end if;

  -- Any trace of earlier content keeps the notebook.
  if v_revision <> 0 or v_title_source <> 'auto'
     or v_transcript_forgotten_at is not null
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
     or exists (select 1 from public.memory_facts where source_notebook_id = p_notebook_id)
     or exists (select 1 from public.conversation_state where notebook_id = p_notebook_id)
  then
    return jsonb_build_object('deleted', false);
  end if;

  delete from public.retrieve_rate_limits
    where scope = 'notebook:' || p_notebook_id::text;
  delete from public.notebooks where id = p_notebook_id and user_id = auth.uid();
  return jsonb_build_object('deleted', true);
end;
$$;

revoke all on function public.delete_empty_notebook(uuid) from public, anon;
grant execute on function public.delete_empty_notebook(uuid) to authenticated;
