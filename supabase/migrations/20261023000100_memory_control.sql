-- LM-29: edit and remove what Lumen keeps.
--
-- Two user controls over the shared memory, and the server-side enforcement
-- that makes both stick:
--   edit_entity_description(id, text)  — user-written description on every
--                                         one of the caller's rows for the id
--   remove_entity(id)                  — delete the entity everywhere the
--                                         caller has it, and suppress the id
--                                         so no later commit brings it back
--   _commit_apply_turn (replaced)      — drops suppressed ids before
--                                         validating; never overwrites a
--                                         user-written description
--   get_notebook_snapshot (replaced)   — adds descriptionSource and the
--                                         caller's suppressedEntityIds
--
-- Both function replacements are copied verbatim from
-- 20260821000000_notebook_commit_module.sql; only the LM-29-commented parts
-- differ. Anything else that replaces _commit_apply_turn (captures, the
-- journal_entries.turn_id follow-up) must start from THIS body.
--
-- Not touched on purpose: conversation_turns. Removing an entity does not
-- redact what was said; only the memory forgets it.

-- ────────────────────────────────────────────────────────────
-- 1. entities.description_source
-- ────────────────────────────────────────────────────────────
alter table public.entities
  add column description_source text not null default 'extracted'
    constraint entities_description_source_check
    check (description_source in ('extracted', 'user'));

-- ────────────────────────────────────────────────────────────
-- 2. entity_suppressions — ids the user removed from memory
--
-- User-wide (an entity id is a slug shared across notebooks). Readable by
-- the owner; written only by remove_entity below.
-- ────────────────────────────────────────────────────────────
create table public.entity_suppressions (
  user_id    uuid not null references auth.users(id) on delete cascade,
  entity_id  text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, entity_id)
);

alter table public.entity_suppressions enable row level security;

create policy "owner select" on public.entity_suppressions
  for select using (auth.uid() = user_id);

revoke all on table public.entity_suppressions from anon;
revoke insert, update, delete, truncate on table public.entity_suppressions from authenticated;

-- ────────────────────────────────────────────────────────────
-- 3. edit_entity_description
--
-- SECURITY DEFINER: direct entity writes were revoked from authenticated in
-- 20260821. Every statement filters by auth.uid(). Affected notebooks are
-- locked before their entity rows, the same order commit_notebook uses, so
-- an edit racing a commit serializes instead of deadlocking; the revision
-- bump then makes the racing device's next commit conflict and reload.
-- ────────────────────────────────────────────────────────────
create or replace function public.edit_entity_description(
  p_entity_id text,
  p_text text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  -- 800 = the extractor's description limit (infra/lambda/extract-graph/prompts.mjs).
  v_text text := left(btrim(p_text, E' \t\r\n'), 800);
  v_notebooks uuid[];
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if v_text is null or v_text = '' then
    raise exception 'description is required' using errcode = '22023';
  end if;

  select coalesce(array_agg(locked.id), '{}') into v_notebooks
    from (
      select nb.id from public.notebooks nb
      where nb.user_id = v_uid
        and exists (
          select 1 from public.entities e
          where e.user_id = v_uid and e.notebook_id = nb.id and e.id = p_entity_id
        )
      order by nb.id
      for update
    ) locked;

  update public.entities
    set description = v_text,
        description_source = 'user'
    where user_id = v_uid and id = p_entity_id and notebook_id = any(v_notebooks);

  update public.notebooks
    set revision = revision + 1,
        updated_at = now()
    where user_id = v_uid and id = any(v_notebooks);

  return jsonb_build_object('updatedNotebooks', cardinality(v_notebooks));
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. remove_entity
--
-- SECURITY DEFINER, so it bypasses RLS: EVERY statement below filters by
-- user_id = v_uid. Another user's identical slug must never be touched.
-- Deletes rows (remove means gone); undo is the client's 5-second delay
-- before calling this, not a server restore. Idempotent: a retry finds
-- nothing left to delete and re-inserts nothing (removedFrom = 0).
-- ────────────────────────────────────────────────────────────
create or replace function public.remove_entity(
  p_entity_id text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_notebooks uuid[];
  v_removed_from integer;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;

  -- Every notebook of the caller's that this removal will change, locked
  -- first (commit_notebook's lock order: notebook, then its children).
  select coalesce(array_agg(locked.id), '{}') into v_notebooks
    from (
      select nb.id from public.notebooks nb
      where nb.user_id = v_uid
        and (
          exists (select 1 from public.entities e
                  where e.user_id = v_uid and e.notebook_id = nb.id and e.id = p_entity_id)
          or exists (select 1 from public.relations r
                     where r.user_id = v_uid and r.notebook_id = nb.id
                       and p_entity_id in (r.source_id, r.target_id))
          or exists (select 1 from public.journal_entries je
                     where je.user_id = v_uid and je.notebook_id = nb.id
                       and p_entity_id = any(je.entity_ids))
          or exists (select 1 from public.follow_ups f
                     where f.user_id = v_uid and f.notebook_id = nb.id
                       and p_entity_id = any(f.target_entity_ids))
          or exists (select 1 from public.asked_questions a
                     where a.user_id = v_uid and a.notebook_id = nb.id
                       and p_entity_id = any(a.target_entity_ids))
        )
      order by nb.id
      for update
    ) locked;

  -- Relations first, so their ids can be stripped from the entries of the
  -- same notebook (relation ids are only unique per notebook).
  with deleted_relations as (
    delete from public.relations
    where user_id = v_uid and p_entity_id in (source_id, target_id)
    returning notebook_id, id
  ), by_notebook as (
    select notebook_id, array_agg(id) as ids from deleted_relations group by notebook_id
  )
  update public.journal_entries je
    set relation_ids = array(
      select x from unnest(je.relation_ids) with ordinality as t(x, ord)
      where not (x = any(d.ids))
      order by ord
    )
    from by_notebook d
    where je.user_id = v_uid and je.notebook_id = d.notebook_id and je.relation_ids && d.ids;

  update public.journal_entries
    set entity_ids = array_remove(entity_ids, p_entity_id)
    where user_id = v_uid and p_entity_id = any(entity_ids);

  update public.follow_ups
    set target_entity_ids = array_remove(target_entity_ids, p_entity_id)
    where user_id = v_uid and p_entity_id = any(target_entity_ids);

  update public.asked_questions
    set target_entity_ids = array_remove(target_entity_ids, p_entity_id)
    where user_id = v_uid and p_entity_id = any(target_entity_ids);

  delete from public.entity_embeddings
    where user_id = v_uid and entity_id = p_entity_id;

  with deleted_entities as (
    delete from public.entities
    where user_id = v_uid and id = p_entity_id
    returning notebook_id
  )
  select count(distinct notebook_id)::integer into v_removed_from from deleted_entities;

  insert into public.entity_suppressions (user_id, entity_id)
    values (v_uid, p_entity_id)
    on conflict (user_id, entity_id) do nothing;

  update public.notebooks nb
    set revision = nb.revision + 1,
        updated_at = now(),
        entity_count = (select count(*) from public.entities e where e.notebook_id = nb.id)
    where nb.user_id = v_uid and nb.id = any(v_notebooks);

  return jsonb_build_object('removedFrom', v_removed_from);
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 5. _commit_apply_turn — replaced (see header)
-- ────────────────────────────────────────────────────────────
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
      case when value->'questions' is null then null
           else array(select jsonb_array_elements_text(value->'questions')) end
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

-- ────────────────────────────────────────────────────────────
-- 6. get_notebook_snapshot — replaced (see header)
-- ────────────────────────────────────────────────────────────
create or replace function public.get_notebook_snapshot(
  p_notebook_id uuid
) returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when nb.id is null then null else jsonb_build_object(
    'notebookId', nb.id,
    'revision', nb.revision,
    -- LM-29: user-wide, not per notebook — merge.dart skips these ids so a
    -- removed entity never reappears on the device either.
    'suppressedEntityIds', coalesce((
      select jsonb_agg(s.entity_id order by s.entity_id)
      from public.entity_suppressions s where s.user_id = nb.user_id
    ), '[]'::jsonb),
    'state', jsonb_build_object(
      'entries', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', e.id, 'text', e.text, 'createdAt', e.created_at,
          'entityIds', to_jsonb(e.entity_ids), 'relationIds', to_jsonb(e.relation_ids)
        ) order by e.created_at desc)
        from public.journal_entries e where e.notebook_id = nb.id
      ), '[]'::jsonb),
      'entities', coalesce((
        select jsonb_object_agg(en.id, jsonb_build_object(
          'id', en.id, 'name', en.name, 'type', en.type, 'description', en.description,
          'descriptionSource', en.description_source,
          'metadata', en.metadata, 'mentions', en.mentions,
          'firstSeen', en.first_seen, 'lastSeen', en.last_seen,
          'questions', case when en.questions is null then null else to_jsonb(en.questions) end
        ))
        from public.entities en where en.notebook_id = nb.id
      ), '{}'::jsonb),
      'relations', coalesce((
        select jsonb_object_agg(r.id, jsonb_build_object(
          'id', r.id, 'source', r.source_id, 'target', r.target_id, 'label', r.label,
          'metadata', r.metadata, 'createdAt', r.created_at, 'supersededAt', r.superseded_at
        ))
        from public.relations r where r.notebook_id = nb.id
      ), '{}'::jsonb),
      'followUps', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', f.id, 'question', f.question, 'reason', f.reason,
          'targetEntityIds', to_jsonb(f.target_entity_ids),
          'createdAt', f.created_at, 'answered', f.answered
        ) order by f.created_at desc)
        from public.follow_ups f where f.notebook_id = nb.id
      ), '[]'::jsonb),
      'askedQuestions', coalesce((
        select jsonb_agg(jsonb_build_object(
          'question', a.question, 'targetEntityIds', to_jsonb(a.target_entity_ids), 'askedAt', a.asked_at
        ) order by a.asked_at desc)
        from (
          select * from public.asked_questions where notebook_id = nb.id
          order by asked_at desc limit 30
        ) a
      ), '[]'::jsonb)
    )
  ) end
  from public.notebooks nb
  where nb.id = p_notebook_id and nb.user_id = auth.uid();
$$;

-- ────────────────────────────────────────────────────────────
-- 7. Grants
--
-- create or replace keeps the replaced functions' existing grants; the two
-- new RPCs are for signed-in users only.
-- ────────────────────────────────────────────────────────────
revoke all on function public.edit_entity_description(text, text) from public, anon;
grant execute on function public.edit_entity_description(text, text) to authenticated;

revoke all on function public.remove_entity(text) from public, anon;
grant execute on function public.remove_entity(text) to authenticated;
