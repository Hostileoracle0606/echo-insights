-- LM-49: forget a person.
--
--   suppression_keys          — a random key per user (private table)
--   entity_suppressions       — entity_id (readable slug) becomes entity_hash,
--                               encode(hmac(slug, user key, 'sha256'), 'hex'),
--                               so the table no longer holds a name. Existing
--                               rows are rehashed here.
--   remove_entity (replaced)  — writes the hash
--   _commit_apply_turn        — compares hashes; otherwise 20261028000000's body
--    (replaced)
--   get_notebook_snapshot     — no longer lists suppressed ids (a device cannot
--    (replaced)                 hash them); the field stays, empty
--   forget_entity_preview(id) — what "Forget" would remove, as counts
--   forget_entity(id)         — the entity in every notebook of the caller's,
--                               the follow-ups and asked questions about it,
--                               a brief that mentions it, and its name redacted
--                               from cards and notebook titles/summaries
--
-- Not touched on purpose: the words the user spoke (conversation_turns,
-- journal_entries) and other entities' descriptions; as with remove_entity,
-- only the memory forgets. Cards are redacted, never regenerated (no model
-- call in the database).
--
-- Any later replacement of _commit_apply_turn must start from THIS body.

create extension if not exists pgcrypto with schema extensions;

-- ────────────────────────────────────────────────────────────
-- 1. suppression_keys — private: RLS on, no policies, no grants. Only the
-- SECURITY DEFINER functions below read it.
-- ────────────────────────────────────────────────────────────
create table public.suppression_keys (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  key        bytea not null,
  created_at timestamptz not null default now()
);
alter table public.suppression_keys enable row level security;
revoke all on table public.suppression_keys from anon, authenticated;

-- The user's key, created on first use.
create or replace function public._suppression_key(p_uid uuid)
returns bytea
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_key bytea;
begin
  insert into public.suppression_keys (user_id, key)
    values (p_uid, gen_random_bytes(32))
    on conflict (user_id) do nothing;
  select k.key into v_key from public.suppression_keys k where k.user_id = p_uid;
  return v_key;
end;
$$;

create or replace function public._suppression_hash(p_uid uuid, p_entity_id text)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  return encode(hmac(convert_to(p_entity_id, 'UTF8'), public._suppression_key(p_uid), 'sha256'), 'hex');
end;
$$;

-- The ids among p_ids the user has suppressed. A user with no key has no
-- suppressions, so nothing is created on the commit path.
create or replace function public._suppressed_ids(p_uid uuid, p_ids text[])
returns text[]
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_key bytea;
begin
  select k.key into v_key from public.suppression_keys k where k.user_id = p_uid;
  if v_key is null or p_ids is null then
    return '{}';
  end if;
  return coalesce((
    select array_agg(x) from (select distinct unnest(p_ids) as x) ids
    where exists (
      select 1 from public.entity_suppressions s
      where s.user_id = p_uid
        and s.entity_hash = encode(hmac(convert_to(ids.x, 'UTF8'), v_key, 'sha256'), 'hex'))
  ), '{}');
end;
$$;

revoke all on function public._suppression_key(uuid) from public, anon, authenticated;
revoke all on function public._suppression_hash(uuid, text) from public, anon, authenticated;
revoke all on function public._suppressed_ids(uuid, text[]) from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 2. entity_suppressions: slug -> keyed hash, existing rows included
-- ────────────────────────────────────────────────────────────
alter table public.entity_suppressions rename column entity_id to entity_hash;

update public.entity_suppressions s
  set entity_hash = public._suppression_hash(s.user_id, s.entity_hash);

-- ────────────────────────────────────────────────────────────
-- 3. remove_entity — replaced; 20261023000100's body with the hashed insert
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

  insert into public.entity_suppressions (user_id, entity_hash)
    values (v_uid, public._suppression_hash(v_uid, p_entity_id))
    on conflict (user_id, entity_hash) do nothing;

  update public.notebooks nb
    set revision = nb.revision + 1,
        updated_at = now(),
        entity_count = (select count(*) from public.entities e where e.notebook_id = nb.id)
    where nb.user_id = v_uid and nb.id = any(v_notebooks);

  return jsonb_build_object('removedFrom', v_removed_from);
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. _commit_apply_turn — replaced (see header)
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
  -- LM-49: suppressions are keyed hashes, so the incoming ids are hashed and
  -- compared; the readable slug is never stored.
  v_suppressed := public._suppressed_ids(p_uid, array(
    select x from (
      select value->>'id' as x from jsonb_array_elements(v_entities)
      union select value->>'source' from jsonb_array_elements(v_relations)
      union select value->>'target' from jsonb_array_elements(v_relations)
      union select jsonb_array_elements_text(coalesce(v_entry->'entityIds', '[]'::jsonb))
      union select jsonb_array_elements_text(case when jsonb_typeof(v_follow_up->'targetEntityIds') = 'array'
                                                  then v_follow_up->'targetEntityIds' else '[]'::jsonb end)
      union select jsonb_array_elements_text(case when jsonb_typeof(v_asked->'targetEntityIds') = 'array'
                                                  then v_asked->'targetEntityIds' else '[]'::jsonb end)
    ) c where x is not null));

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

-- ────────────────────────────────────────────────────────────
-- 5. get_notebook_snapshot — replaced (see header)
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
    -- LM-49: suppressions are keyed hashes the device cannot compare, so the
    -- readable ids are no longer sent. The field stays (empty) for older
    -- clients; the server drops suppressed ids in every commit.
    'suppressedEntityIds', '[]'::jsonb,
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
-- 6. JSON helpers for finding and redacting a name inside card/brief JSON.
-- They walk string VALUES only: keys and structure are never changed, so a
-- person called "summary" cannot corrupt a card.
-- ────────────────────────────────────────────────────────────

-- A regex matching any of p_names as whole words, case-insensitively
-- (flag 'i' at use), or null when there are none.
create or replace function public._name_pattern(p_names text[])
returns text
language sql
immutable
as $$
  select case when count(*) = 0 then null
    else '(?<![[:alnum:]])(' || string_agg(regexp_replace(n, '([.*+?^${}()|\[\]\\])', '\\\1', 'g'), '|') || ')(?![[:alnum:]])'
  end
  from unnest(p_names) n where btrim(n) <> '';
$$;

-- True when a string in p_json matches p_pat or equals p_entity_id.
create or replace function public._jsonb_mentions(p_json jsonb, p_pat text, p_entity_id text)
returns boolean
language sql
immutable
as $$
  select exists (
    select 1 from jsonb_path_query(p_json, 'strict $.**') v
    where jsonb_typeof(v) = 'string'
      and ((v #>> '{}') = p_entity_id or (p_pat is not null and (v #>> '{}') ~* p_pat))
  );
$$;

-- p_json with matches of p_pat replaced by p_repl in every string value, and
-- any object that carries "entityId": p_entity_id dropped from its array.
create or replace function public._jsonb_redact(p_json jsonb, p_pat text, p_entity_id text, p_repl text)
returns jsonb
language plpgsql
immutable
as $$
begin
  case jsonb_typeof(p_json)
    when 'string' then
      if p_pat is null then return p_json; end if;
      return to_jsonb(regexp_replace(p_json #>> '{}', p_pat, p_repl, 'gi'));
    when 'array' then
      return coalesce((
        select jsonb_agg(public._jsonb_redact(v, p_pat, p_entity_id, p_repl) order by ord)
        from jsonb_array_elements(p_json) with ordinality as t(v, ord)
        where not (jsonb_typeof(v) = 'object' and v ->> 'entityId' = p_entity_id)
      ), '[]'::jsonb);
    when 'object' then
      return coalesce((
        select jsonb_object_agg(k, public._jsonb_redact(v, p_pat, p_entity_id, p_repl))
        from jsonb_each(p_json) as t(k, v)
      ), '{}'::jsonb);
    else
      return p_json;
  end case;
end;
$$;

revoke all on function public._name_pattern(text[]) from public, anon, authenticated;
revoke all on function public._jsonb_mentions(jsonb, text, text) from public, anon, authenticated;
revoke all on function public._jsonb_redact(jsonb, text, text, text) from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 7. forget_entity_preview / forget_entity
--
-- SECURITY DEFINER; every statement filters by v_uid = auth.uid(). The names
-- to look for are the name(s) this user's entity rows carry for the id.
-- A follow-up or asked question goes when it targets the id or its text
-- mentions the name.
-- ────────────────────────────────────────────────────────────
create or replace function public._forget_counts(p_uid uuid, p_entity_id text, p_pat text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'notebooks', (select count(distinct e.notebook_id) from public.entities e
                  where e.user_id = p_uid and e.id = p_entity_id),
    'relations', (select count(*) from public.relations r
                  where r.user_id = p_uid and p_entity_id in (r.source_id, r.target_id)),
    'followUps', (select count(*) from public.follow_ups f
                  where f.user_id = p_uid
                    and (p_entity_id = any(f.target_entity_ids)
                         or (p_pat is not null and f.question ~* p_pat))),
    'askedQuestions', (select count(*) from public.asked_questions a
                       where a.user_id = p_uid
                         and (p_entity_id = any(a.target_entity_ids)
                              or (p_pat is not null and a.question ~* p_pat))),
    'cards', (select count(*) from public.session_cards c
              where c.user_id = p_uid and public._jsonb_mentions(c.card, p_pat, p_entity_id)),
    'briefDeleted', exists (select 1 from public.session_briefs b
                            where b.user_id = p_uid and public._jsonb_mentions(b.brief, p_pat, p_entity_id))
  );
$$;
revoke all on function public._forget_counts(uuid, text, text) from public, anon, authenticated;

create or replace function public.forget_entity_preview(p_entity_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;
  return public._forget_counts(v_uid, p_entity_id, public._name_pattern(
    array(select distinct e.name from public.entities e where e.user_id = v_uid and e.id = p_entity_id)));
end;
$$;

create or replace function public.forget_entity(p_entity_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_pat text;
  v_counts jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;

  -- Every notebook of the caller's, in id order (commit_notebook's lock
  -- order), so cards and titles are redacted without racing a commit.
  perform 1 from public.notebooks where user_id = v_uid order by id for update;

  v_pat := public._name_pattern(
    array(select distinct e.name from public.entities e where e.user_id = v_uid and e.id = p_entity_id));
  v_counts := public._forget_counts(v_uid, p_entity_id, v_pat);

  -- Questions about the person go whole (remove_entity only strips the id).
  delete from public.follow_ups
    where user_id = v_uid
      and (p_entity_id = any(target_entity_ids) or (v_pat is not null and question ~* v_pat));
  delete from public.asked_questions
    where user_id = v_uid
      and (p_entity_id = any(target_entity_ids) or (v_pat is not null and question ~* v_pat));

  -- The entity, relations, embeddings and provenance ids, then the hashed
  -- suppression and the revision bump.
  perform public.remove_entity(p_entity_id);

  -- A brief that mentions the person is deleted (its audio goes with it).
  delete from public.session_briefs b
    where b.user_id = v_uid and public._jsonb_mentions(b.brief, v_pat, p_entity_id);

  -- Cards are redacted, not regenerated.
  update public.session_cards c
    set card = public._jsonb_redact(c.card, v_pat, p_entity_id, 'someone'),
        updated_at = now()
    where c.user_id = v_uid and public._jsonb_mentions(c.card, v_pat, p_entity_id);

  if v_pat is not null then
    update public.notebooks
      set title = regexp_replace(title, v_pat, 'someone', 'gi'),
          summary = regexp_replace(summary, v_pat, 'someone', 'gi')
      where user_id = v_uid and (title ~* v_pat or summary ~* v_pat);
  end if;

  return v_counts;
end;
$$;

revoke all on function public.forget_entity_preview(text) from public, anon;
grant execute on function public.forget_entity_preview(text) to authenticated;
revoke all on function public.forget_entity(text) from public, anon;
grant execute on function public.forget_entity(text) to authenticated;
