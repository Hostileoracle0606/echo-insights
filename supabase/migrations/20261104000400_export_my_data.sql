-- LM-52: export_my_data() — everything the signed-in user wrote or Lumen
-- derived from it, as one JSON object, for "Export my journal".
--
--   { version, exportedAt, notebooks: [{ id, title, …, turns, journalEntries,
--     card, entities, relations, followUps, askedQuestions }] }
--
-- SECURITY DEFINER, so it bypasses RLS: every subquery is reached through
-- notebooks.user_id = auth.uid(). There is no user parameter. The optional
-- p_notebook_ids only NARROWS the caller's own notebooks (another user's id in
-- it matches nothing); the app uses it to fetch a long-time user's journal a
-- few notebooks at a time, so one response stays small and under the
-- statement timeout; more than 50 ids is refused (22023). Called with no argument it returns every notebook.
--
-- Left out on purpose: internal bookkeeping (retrieve_rate_limits,
-- notebook_commit_requests, conversation_runtime_*, entity_suppressions,
-- suppression_keys), embeddings, and session_briefs (its audio is bytea).
-- session_cards holds a draft as well as the final card, whichever is newest.
-- user_id and revision are not exported either: the first is the caller's own
-- id, the second is an internal concurrency counter.
--
-- Item shapes match get_notebook_snapshot (same camelCase keys), except that
-- entities and relations are arrays rather than id-keyed objects.
create or replace function public.export_my_data(
  p_notebook_ids uuid[] default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if cardinality(p_notebook_ids) > 50 then
    raise exception 'too many notebook ids' using errcode = '22023';
  end if;

  return (select jsonb_build_object(
    'version', 1,
    'exportedAt', now(),
    'notebooks', coalesce(jsonb_agg(
      jsonb_build_object(
        'id', nb.id,
        'title', nb.title,
        'titleSource', nb.title_source,
        'startedAt', nb.started_at,
        'endedAt', nb.ended_at,
        'durationSeconds', nb.duration_seconds,
        'entityCount', nb.entity_count,
        'summary', nb.summary,
        'archivedAt', nb.archived_at,
        'createdAt', nb.created_at,
        'updatedAt', nb.updated_at,
        'conversationMode', nb.conversation_mode,
        'modeContext', nb.mode_context,
        'turns', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', t.turn_id, 'speaker', t.speaker, 'text', t.text,
            'spokenAt', t.spoken_at, 'input', t.input
          ) order by t.spoken_at, t.turn_id)
          from public.conversation_turns t where t.notebook_id = nb.id
        ), '[]'::jsonb),
        'journalEntries', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', e.id, 'text', e.text, 'createdAt', e.created_at,
            'entityIds', to_jsonb(e.entity_ids), 'relationIds', to_jsonb(e.relation_ids)
          ) order by e.created_at, e.id)
          from public.journal_entries e where e.notebook_id = nb.id
        ), '[]'::jsonb),
        'card', (select c.card from public.session_cards c where c.notebook_id = nb.id),
        'entities', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', en.id, 'name', en.name, 'type', en.type, 'description', en.description,
            'descriptionSource', en.description_source,
            'metadata', en.metadata, 'mentions', en.mentions,
            'firstSeen', en.first_seen, 'lastSeen', en.last_seen,
            'questions', case when en.questions is null then null else to_jsonb(en.questions) end
          ) order by en.id)
          from public.entities en where en.notebook_id = nb.id
        ), '[]'::jsonb),
        'relations', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', r.id, 'source', r.source_id, 'target', r.target_id, 'label', r.label,
            'metadata', r.metadata, 'createdAt', r.created_at, 'supersededAt', r.superseded_at
          ) order by r.id)
          from public.relations r where r.notebook_id = nb.id
        ), '[]'::jsonb),
        'followUps', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', f.id, 'question', f.question, 'reason', f.reason,
            'targetEntityIds', to_jsonb(f.target_entity_ids),
            'createdAt', f.created_at, 'answered', f.answered
          ) order by f.created_at, f.id)
          from public.follow_ups f where f.notebook_id = nb.id
        ), '[]'::jsonb),
        'askedQuestions', coalesce((
          select jsonb_agg(jsonb_build_object(
            'question', a.question, 'targetEntityIds', to_jsonb(a.target_entity_ids),
            'askedAt', a.asked_at
          ) order by a.asked_at, a.id)
          from public.asked_questions a where a.notebook_id = nb.id
        ), '[]'::jsonb)
      ) order by nb.started_at, nb.id
    ), '[]'::jsonb)
  )
  from public.notebooks nb
  where nb.user_id = auth.uid()
    and (p_notebook_ids is null or nb.id = any (p_notebook_ids)));
end;
$$;

revoke all on function public.export_my_data(uuid[]) from public, anon;
grant execute on function public.export_my_data(uuid[]) to authenticated;
