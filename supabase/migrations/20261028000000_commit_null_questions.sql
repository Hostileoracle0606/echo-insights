-- commit_notebook: accept `"questions": null` on an entity.
--
-- The Flutter client serialises Entity.questions without includeIfNull, so an
-- entity with no open questions arrives as `"questions": null`: a JSON null,
-- not a missing key. `value->'questions' is null` is false for a JSON null, so
-- jsonb_array_elements_text ran on it and raised "cannot extract elements from
-- a scalar". commit_notebook's handler turned that into `commitFailed` and
-- rolled the whole turn back, so since 20260821 no extracted entity, relation
-- or entry from such a turn has reached the database.
--
-- _commit_apply_turn below is 20261023000100's definition verbatim except for
-- the `questions` guard, which now tests jsonb_typeof(...) = 'array'.
-- create or replace keeps the existing grants (service-internal; see 20260821).

create or replace function public._commit_apply_turn(
  p_notebook_id uuid,
  p_uid uuid,
  p_change jsonb
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_entry jsonb := p_change->'entry';
  v_entry_text text := v_entry->>'text';
  v_entities jsonb := coalesce(p_change->'entities', '[]'::jsonb);
  v_relations jsonb := coalesce(p_change->'relations', '[]'::jsonb);
  v_follow_up jsonb := p_change->'followUp';
  v_asked jsonb := p_change->'askedQuestion';
  v_incoming_entity_ids text[];
  v_incoming_relation_ids text[];
  v_entry_entity_ids text[];
  v_entry_relation_ids text[];
  v_bad text;
  v_entry_id uuid;
  v_follow_up_id uuid;
  v_suppressed text[];
  v_dropped_relation_ids text[];
begin
  -- LM-29: a removed entity never lands again. Drop it, every relation that
  -- touches it, and their ids from the entry (and from the follow-up /
  -- asked-question targets) BEFORE validation, so a turn that still mentions
  -- it commits the rest instead of failing invalidChange on a dangling
  -- relation endpoint.
  select coalesce(array_agg(s.entity_id), '{}') into v_suppressed
    from public.entity_suppressions s
    where s.user_id = p_uid;

  if cardinality(v_suppressed) > 0 then
    select coalesce(array_agg(value->>'id'), '{}') into v_dropped_relation_ids
      from jsonb_array_elements(v_relations)
      where value->>'source' = any(v_suppressed) or value->>'target' = any(v_suppressed);

    v_entities := coalesce((
      select jsonb_agg(value order by ord) from jsonb_array_elements(v_entities) with ordinality as t(value, ord)
      where not (coalesce(value->>'id', '') = any(v_suppressed))
    ), '[]'::jsonb);
    v_relations := coalesce((
      select jsonb_agg(value order by ord) from jsonb_array_elements(v_relations) with ordinality as t(value, ord)
      where not (coalesce(value->>'id', '') = any(v_dropped_relation_ids))
    ), '[]'::jsonb);

    if v_entry is not null then
      v_entry := v_entry
        || jsonb_build_object(
             'entityIds', coalesce((
               select jsonb_agg(x order by ord)
               from jsonb_array_elements_text(coalesce(v_entry->'entityIds', '[]'::jsonb)) with ordinality as t(x, ord)
               where not (x = any(v_suppressed))
             ), '[]'::jsonb),
             'relationIds', coalesce((
               select jsonb_agg(x order by ord)
               from jsonb_array_elements_text(coalesce(v_entry->'relationIds', '[]'::jsonb)) with ordinality as t(x, ord)
               where not (x = any(v_dropped_relation_ids))
             ), '[]'::jsonb));
    end if;

    if v_follow_up is not null and jsonb_typeof(v_follow_up->'targetEntityIds') = 'array' then
      v_follow_up := v_follow_up || jsonb_build_object('targetEntityIds', coalesce((
        select jsonb_agg(x order by ord)
        from jsonb_array_elements_text(v_follow_up->'targetEntityIds') with ordinality as t(x, ord)
        where not (x = any(v_suppressed))
      ), '[]'::jsonb));
    end if;
    if v_asked is not null and jsonb_typeof(v_asked->'targetEntityIds') = 'array' then
      v_asked := v_asked || jsonb_build_object('targetEntityIds', coalesce((
        select jsonb_agg(x order by ord)
        from jsonb_array_elements_text(v_asked->'targetEntityIds') with ordinality as t(x, ord)
        where not (x = any(v_suppressed))
      ), '[]'::jsonb));
    end if;
  end if;

  if v_entry_text is null or length(trim(v_entry_text)) = 0 then
    raise exception 'invalidChange: entry.text is required';
  end if;
  if length(v_entry_text) > 8000 then
    raise exception 'invalidChange: entry.text too long';
  end if;
  if jsonb_array_length(v_entities) > 50 or jsonb_array_length(v_relations) > 50 then
    raise exception 'invalidChange: too many entities/relations in one commit';
  end if;

  select coalesce(array_agg(value->>'id'), '{}') into v_incoming_entity_ids
    from jsonb_array_elements(v_entities);
  select coalesce(array_agg(value->>'id'), '{}') into v_incoming_relation_ids
    from jsonb_array_elements(v_relations);

  -- Entity type must be one of the fixed set the clients render.
  select value->>'type' into v_bad
    from jsonb_array_elements(v_entities)
    where coalesce(value->>'id', '') = '' or coalesce(value->>'name', '') = ''
       or (value->>'type') not in
          ('person', 'place', 'organization', 'project', 'event', 'activity', 'concept', 'emotion', 'other')
    limit 1;
  if v_bad is not null then
    raise exception 'invalidChange: bad entity %', v_bad;
  end if;

  -- Relation endpoints must resolve — either an existing active-or-superseded
  -- entity row, or an entity arriving in this same commit (new entity + new
  -- relation created together in one turn).
  select value->>'source' into v_bad
    from jsonb_array_elements(v_relations) as r
    where coalesce(value->>'id', '') = '' or coalesce(value->>'label', '') = ''
       or (
         not exists (
           select 1 from public.entities e
           where e.notebook_id = p_notebook_id and e.id = r.value->>'source'
         )
         and not (v_incoming_entity_ids @> array[r.value->>'source'])
       )
       or (
         not exists (
           select 1 from public.entities e
           where e.notebook_id = p_notebook_id and e.id = r.value->>'target'
         )
         and not (v_incoming_entity_ids @> array[r.value->>'target'])
       )
    limit 1;
  if v_bad is not null then
    raise exception 'invalidChange: relation endpoint % not found', v_bad;
  end if;

  -- Entry provenance ids must reference something real (pre-existing or
  -- arriving in this commit) — never a dangling reference.
  select coalesce(array_agg(x), '{}') into v_entry_entity_ids
    from jsonb_array_elements_text(coalesce(v_entry->'entityIds', '[]'::jsonb)) as x;
  select coalesce(array_agg(x), '{}') into v_entry_relation_ids
    from jsonb_array_elements_text(coalesce(v_entry->'relationIds', '[]'::jsonb)) as x;

  select x into v_bad from unnest(v_entry_entity_ids) as x
    where not (v_incoming_entity_ids @> array[x])
      and not exists (
        select 1 from public.entities e where e.notebook_id = p_notebook_id and e.id = x
      )
    limit 1;
  if v_bad is not null then
    raise exception 'invalidChange: entry references unknown entity %', v_bad;
  end if;

  select x into v_bad from unnest(v_entry_relation_ids) as x
    where not (v_incoming_relation_ids @> array[x])
      and not exists (
        select 1 from public.relations rel where rel.notebook_id = p_notebook_id and rel.id = x
      )
    limit 1;
  if v_bad is not null then
    raise exception 'invalidChange: entry references unknown relation %', v_bad;
  end if;

  if v_follow_up is not null and coalesce(v_follow_up->>'question', '') = '' then
    raise exception 'invalidChange: followUp.question is required';
  end if;
  if v_asked is not null and coalesce(v_asked->>'question', '') = '' then
    raise exception 'invalidChange: askedQuestion.question is required';
  end if;

  -- ── apply ──────────────────────────────────────────────────
  insert into public.journal_entries
    (id, user_id, notebook_id, text, created_at, entity_ids, relation_ids)
  values
    (gen_random_uuid(), p_uid, p_notebook_id, v_entry_text, now(), v_entry_entity_ids, v_entry_relation_ids)
  returning id into v_entry_id;

  if jsonb_array_length(v_entities) > 0 then
    insert into public.entities
      (id, user_id, notebook_id, name, type, description, description_source, metadata, mentions, first_seen, last_seen, questions)
    select
      value->>'id', p_uid, p_notebook_id, value->>'name', value->>'type',
      -- LM-29: a new row whose id the user already described in another of
      -- their notebooks starts from that text (and stays user-written).
      coalesce(u.description, value->>'description'),
      case when u.description is not null then 'user' else 'extracted' end,
      coalesce(value->'metadata', '{}'::jsonb),
      (value->>'mentions')::integer,
      coalesce((value->>'firstSeen')::timestamptz, now()),
      coalesce((value->>'lastSeen')::timestamptz, now()),
      case when jsonb_typeof(value->'questions') = 'array'
           then array(select jsonb_array_elements_text(value->'questions'))
           else null end
    from jsonb_array_elements(v_entities)
    left join lateral (
      select ue.description
      from public.entities ue
      where ue.user_id = p_uid and ue.id = value->>'id' and ue.description_source = 'user'
      limit 1
    ) u on true
    on conflict (notebook_id, id) do update set
      name = excluded.name,
      type = excluded.type,
      -- LM-29: extraction never overwrites what the user wrote, and the
      -- upsert never changes description_source (only edit_entity_description
      -- and the insert above set it).
      description = case when entities.description_source = 'user'
                         then entities.description
                         else excluded.description end,
      metadata = excluded.metadata,
      mentions = excluded.mentions,
      last_seen = excluded.last_seen,
      questions = excluded.questions;
  end if;

  if jsonb_array_length(v_relations) > 0 then
    insert into public.relations
      (id, user_id, notebook_id, source_id, target_id, label, metadata, created_at, superseded_at)
    select
      value->>'id', p_uid, p_notebook_id, value->>'source', value->>'target', value->>'label',
      coalesce(value->'metadata', '{}'::jsonb),
      coalesce((value->>'createdAt')::timestamptz, now()),
      (value->>'supersededAt')::timestamptz
    from jsonb_array_elements(v_relations)
    -- source_id/target_id/label never change for an existing row: the
    -- relation's id IS "<source>__<label>__<target>". Only metadata and the
    -- supersede state are mutable via re-assertion / contradiction.
    on conflict (notebook_id, id) do update set
      metadata = excluded.metadata,
      superseded_at = excluded.superseded_at;
  end if;

  if v_follow_up is not null then
    insert into public.follow_ups
      (id, user_id, notebook_id, question, reason, target_entity_ids, answered, created_at)
    values (
      gen_random_uuid(), p_uid, p_notebook_id, v_follow_up->>'question',
      coalesce(v_follow_up->>'reason', ''),
      coalesce(
        array(select jsonb_array_elements_text(coalesce(v_follow_up->'targetEntityIds', '[]'::jsonb))),
        '{}'
      ),
      false, now()
    )
    returning id into v_follow_up_id;
  end if;

  if v_asked is not null then
    insert into public.asked_questions (user_id, notebook_id, question, target_entity_ids, asked_at)
    values (
      p_uid, p_notebook_id, v_asked->>'question',
      coalesce(
        array(select jsonb_array_elements_text(coalesce(v_asked->'targetEntityIds', '[]'::jsonb))),
        '{}'
      ),
      now()
    );
    -- Same cap the client used to enforce (ASKED_QUESTIONS_CAP = 30):
    -- server-owned now, so both clients read a consistently-trimmed log.
    delete from public.asked_questions
    where notebook_id = p_notebook_id
      and id not in (
        select id from public.asked_questions
        where notebook_id = p_notebook_id
        order by asked_at desc
        limit 30
      );
  end if;

  return jsonb_build_object('ids', jsonb_build_object('entryId', v_entry_id, 'followUpId', v_follow_up_id));
end;
$$;
