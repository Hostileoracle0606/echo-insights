-- EC-08: privacy coverage for the tables EC-02 to EC-07 added
-- (memory_facts, conversation_state, memory_fact_corrections).
--
-- Forget and Remove both write an entity_suppressions row first, in the same
-- transaction (forget_entity, remove_entity). A trigger on that row deletes
-- what the fact layer and the session state derived:
--   * the entity's facts (matched by the same suppression hash), and with
--     them their corrections (foreign key);
--   * after a Forget, any fact whose value names the person, and any session
--     state that does (redact_forgotten changes it).
-- Deleting an entry (auto-forget) or a notebook already cascades to the
-- facts and session state derived from it; deleting the account cascades
-- to everything. export_my_data now includes all three, per notebook.

create or replace function public._purge_derived_memory()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.memory_facts f
   where f.user_id = new.user_id
     and (public._suppression_hash(new.user_id, f.entity_id) = new.entity_hash
          or (f.value_text is not null
              and public.redact_forgotten(new.user_id, f.value_text) <> f.value_text));
  delete from public.conversation_state s
   where s.user_id = new.user_id
     and public.redact_forgotten(new.user_id, s.state::text) <> s.state::text;
  return new;
end;
$$;

revoke all on function public._purge_derived_memory() from public, anon, authenticated;

create trigger purge_derived_memory
  after insert or update on public.entity_suppressions
  for each row execute function public._purge_derived_memory();

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
        ), '[]'::jsonb),
        -- EC-08: what the fact layer, the session state and the correction
        -- flow derived from this notebook. Retracted facts are not exported:
        -- a correction removed them from the user's memory.
        'facts', coalesce((
          select jsonb_agg(public._memory_fact_json(f)
                   order by f.entity_id, f.attribute, coalesce(f.event_at, f.stated_at), f.id)
          from public.memory_facts f
          where f.source_notebook_id = nb.id and f.user_id = auth.uid() and f.retracted_at is null
        ), '[]'::jsonb),
        'sessionState', (
          select s.state from public.conversation_state s
          where s.notebook_id = nb.id and s.user_id = auth.uid()
        ),
        'corrections', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', c.id, 'factId', c.fact_id, 'change', c.change, 'readBack', c.read_back,
            'status', c.status, 'createdAt', c.created_at, 'resolvedAt', c.resolved_at
          ) order by c.created_at, c.id)
          from public.memory_fact_corrections c
          join public.memory_facts f on f.id = c.fact_id
          where f.source_notebook_id = nb.id and c.user_id = auth.uid()
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
