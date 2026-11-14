-- Forget everywhere (LM-63). The user's rule: Lumen never brings up a
-- forgotten person in any of its features, and no graph shows them.
--
-- 1. What Lumen reads of the user's words. journal_entries.text and
-- conversation_turns.text stay verbatim: the transcript view shows the user
-- what they said. Beside each, context_text holds the same words with every
-- forgotten name redacted, or null when there is none to redact. Everything
-- that feeds Lumen reads coalesce(context_text, text): memory quotes
-- (get_entity_mentions), a notebook's entries (get_notebook_snapshot), and the
-- turns the apps send as context.
--
-- Precomputed, not redacted on read: the matcher costs about 0.4 ms per
-- 200-character row (500 turns: 216 ms, local), on every snapshot load and
-- retrieval. Here it runs once per row: on insert, only for a user who has
-- forgotten someone, and on forget, only for rows whose slugged text contains
-- one of the person's slugs. Rows written before this migration are filled
-- by 20261112100100, outside this file's table locks.
--
-- 2. Ids. A slug can spell a forgotten name ("priya-raman-foundation"). Forget
-- renames such entities everywhere they are stored, and a commit renames them
-- on the way in, so no graph payload carries one (BUG-4). Whether an id spells
-- the name is read from the entity's name, with the same rules as any text, so
-- forgetting Will leaves "will-power" alone. The person under another id (a
-- name that redacts to exactly "someone") is removed too.
--
-- 3. Remove (BUG-3). Removing an entity bumps the notebooks it was in. A card
-- that was current and doesn't remember that entity stays current, as Forget
-- already does (R6), so it isn't regenerated for nothing.

-- ────────────────────────────────────────────────────────────
-- 1. context_text
-- ────────────────────────────────────────────────────────────
-- Adding a nullable column is instant, but waits for the table lock: give up
-- rather than queue every read behind a long transaction.
set lock_timeout = '5s';
alter table public.journal_entries add column context_text text;
alter table public.conversation_turns add column context_text text;
reset lock_timeout;

comment on column public.journal_entries.context_text is
  'What Lumen reads: text with forgotten names redacted. Null when text names no forgotten person.';
comment on column public.conversation_turns.context_text is
  'What Lumen reads: text with forgotten names redacted. Null when text names no forgotten person. The transcript view reads text.';

-- p_text with every forgotten name redacted, or null if that changes nothing.
create function public._context_text(p_uid uuid, p_text text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_out text;
begin
  if p_text is null or not exists (
    select 1 from public.entity_suppressions s where s.user_id = p_uid and s.kind = 'forgotten'
  ) then
    return null;
  end if;
  v_out := public.redact_forgotten(p_uid, p_text);
  return case when v_out is distinct from p_text then v_out end;
end;
$$;

-- Kept by the database, whatever a client sends. The share lock on the
-- notebook queues a turn saved during a forget (which holds every notebook
-- for update) until the forget commits, so it is redacted with the new name;
-- a turn saved just before is committed before the forget reads the turns.
create function public._set_context_text()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform 1 from public.notebooks where id = new.notebook_id for share;
  new.context_text := public._context_text(new.user_id, new.text);
  return new;
end;
$$;

create trigger journal_entries_context_text
  before insert or update of text on public.journal_entries
  for each row execute function public._set_context_text();
create trigger conversation_turns_context_text
  before insert or update of text on public.conversation_turns
  for each row execute function public._set_context_text();

-- _slugify without its 60-character cut: the slug of a whole text, so a
-- person's slug can be looked for inside it.
create function public._slug_text(p_text text)
returns text
language sql
immutable
as $$
  select btrim(regexp_replace(
    regexp_replace(normalize(lower(coalesce(p_text, '')), NFKD), '[̀-ͯ]', '', 'g'),
    '[\u0001-/:-@[-`{-¿×÷։־׃،؛؟۔।॥\u2000-⯿　-〿︀-️︰-﹯！-／：-＠［-｀｛-･\U0001f000-\U0001faffÀ-˿Ḁ-ỿⱠ-Ɀ꜠-ꟿ]+', '-', 'g'), '-');
$$;

-- ────────────────────────────────────────────────────────────
-- 2. Ids that spell a forgotten name
-- ────────────────────────────────────────────────────────────

-- The id an entity named p_name is stored under once its forgotten names are
-- redacted: the redacted name, slugged ("priya-raman-foundation" named
-- "Priya Raman Foundation" -> "someone-foundation"). p_id itself when the
-- name names no one forgotten, when the id doesn't spell the name (made from
-- it, or its words read as text name them; a lowercase "will-power" never
-- does), or when the whole name is the person (that id is dropped instead:
-- suppressed on commit, removed on forget).
create function public._redact_id(p_uid uuid, p_id text, p_name text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_name text;
  v_words text := replace(coalesce(p_id, ''), '-', ' ');
  v_out text;
begin
  if coalesce(p_id, '') = '' or coalesce(p_name, '') = '' then
    return p_id;
  end if;
  v_name := public.redact_forgotten(p_uid, p_name);
  if v_name = p_name then
    return p_id;
  end if;
  if p_id <> public._slugify(p_name) and public.redact_forgotten(p_uid, v_words) = v_words then
    return p_id;
  end if;
  v_out := public._slugify(v_name);
  if v_out in ('', 'someone') then
    return p_id;
  end if;
  return v_out;
end;
$$;

-- A relation id is "<source>__<label>__<target>": its ends mapped by p_map.
create function public._map_relation_id(p_id text, p_map jsonb)
returns text
language plpgsql
immutable
as $$
declare
  v_parts text[] := string_to_array(p_id, '__');
begin
  if cardinality(v_parts) <> 3 then
    return p_id;
  end if;
  return coalesce(p_map ->> v_parts[1], v_parts[1]) || '__' || v_parts[2] || '__'
         || coalesce(p_map ->> v_parts[3], v_parts[3]);
end;
$$;

-- Asks embed-entities to embed these notebooks again (the insert trigger's
-- request): a renamed entity lost its embedding with its old id.
create function public._enqueue_embed(p_notebook_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_nb uuid;
  v_url text := (select decrypted_secret from vault.decrypted_secrets where name = 'embed_entities_url');
  v_secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'embed_internal_secret');
begin
  if v_url is null or v_url = '' or v_secret is null or v_secret = '' then
    return;
  end if;
  foreach v_nb in array array(select distinct x from unnest(p_notebook_ids) x) loop
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
      body    := jsonb_build_object('notebookId', v_nb));
  end loop;
end;
$$;

-- p_ids mapped through p_map ({old: new}), each id once, in order.
create function public._map_ids(p_ids text[], p_map jsonb)
returns text[]
language sql
immutable
as $$
  select coalesce(array_agg(x order by o), '{}') from (
    select coalesce(p_map ->> y, y) as x, min(ord) as o
    from unnest(p_ids) with ordinality as t(y, ord)
    group by 1
  ) m;
$$;

-- Rewrites every stored id of p_uid's that spells a forgotten name, judged by
-- the names in p_names ({id: name}, read before the forget redacted them).
-- Where the new id is already taken in that notebook, the old row goes and
-- the one already there stays. Returns the notebooks that changed.
create function public._forget_rename_ids(p_uid uuid, p_names jsonb)
returns uuid[]
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_map jsonb;
  v_rmap jsonb;
  v_touched uuid[] := '{}';
  v_more uuid[];
begin
  select coalesce(jsonb_object_agg(id, new_id), '{}') into v_map from (
    select x.key as id, public._redact_id(p_uid, x.key, x.value) as new_id
    from jsonb_each_text(p_names) x
    where exists (select 1 from public.entities e where e.user_id = p_uid and e.id = x.key)
  ) m where new_id <> id;
  select coalesce(jsonb_object_agg(id, new_id), '{}') into v_rmap from (
    select x.id, public._map_relation_id(x.id, v_map) as new_id
    from (select distinct r.id from public.relations r where r.user_id = p_uid) x
  ) m where new_id <> id;
  if v_map = '{}'::jsonb and v_rmap = '{}'::jsonb then
    return '{}';
  end if;

  -- Entities: one row per (notebook, new id).
  with m as (
    select e.notebook_id, e.id,
           row_number() over (partition by e.notebook_id, v_map ->> e.id order by e.id) as rn,
           exists (select 1 from public.entities t
                   where t.notebook_id = e.notebook_id and t.id = v_map ->> e.id) as taken
    from public.entities e where e.user_id = p_uid and v_map ? e.id
  ), gone as (
    delete from public.entities e using m
     where e.notebook_id = m.notebook_id and e.id = m.id and (m.taken or m.rn > 1)
    returning e.notebook_id
  )
  select coalesce(array_agg(distinct notebook_id), '{}') into v_more from gone;
  v_touched := v_touched || v_more;
  with done as (
    update public.entities e set id = v_map ->> e.id
     where e.user_id = p_uid and v_map ? e.id
    returning e.notebook_id
  )
  select coalesce(array_agg(distinct notebook_id), '{}') into v_more from done;
  v_touched := v_touched || v_more;
  delete from public.entity_embeddings x where x.user_id = p_uid and v_map ? x.entity_id;

  -- Relations: their ends, then their own ids.
  update public.relations r
     set source_id = coalesce(v_map ->> r.source_id, r.source_id),
         target_id = coalesce(v_map ->> r.target_id, r.target_id)
   where r.user_id = p_uid and (v_map ? r.source_id or v_map ? r.target_id);
  with m as (
    select r.notebook_id, r.id,
           row_number() over (partition by r.notebook_id, v_rmap ->> r.id order by r.id) as rn,
           exists (select 1 from public.relations t
                   where t.notebook_id = r.notebook_id and t.id = v_rmap ->> r.id) as taken
    from public.relations r where r.user_id = p_uid and v_rmap ? r.id
  ), gone as (
    delete from public.relations r using m
     where r.notebook_id = m.notebook_id and r.id = m.id and (m.taken or m.rn > 1)
    returning r.notebook_id
  )
  select coalesce(array_agg(distinct notebook_id), '{}') into v_more from gone;
  v_touched := v_touched || v_more;
  with done as (
    update public.relations r set id = v_rmap ->> r.id
     where r.user_id = p_uid and v_rmap ? r.id
    returning r.notebook_id
  )
  select coalesce(array_agg(distinct notebook_id), '{}') into v_more from done;
  v_touched := v_touched || v_more;

  -- Where the ids are referenced.
  update public.journal_entries je
     set entity_ids = public._map_ids(je.entity_ids, v_map),
         relation_ids = public._map_ids(je.relation_ids, v_rmap)
   where je.user_id = p_uid
     and (je.entity_ids && array(select jsonb_object_keys(v_map))
          or je.relation_ids && array(select jsonb_object_keys(v_rmap)));
  update public.follow_ups f set target_entity_ids = public._map_ids(f.target_entity_ids, v_map)
   where f.user_id = p_uid and f.target_entity_ids && array(select jsonb_object_keys(v_map));
  update public.asked_questions a set target_entity_ids = public._map_ids(a.target_entity_ids, v_map)
   where a.user_id = p_uid and a.target_entity_ids && array(select jsonb_object_keys(v_map));
  update public.session_cards c
     set card = jsonb_set(c.card, '{remember}', (
           select coalesce(jsonb_agg(case when jsonb_typeof(r) = 'object' and v_map ? (r ->> 'entityId')
                                          then jsonb_set(r, '{entityId}', to_jsonb(v_map ->> (r ->> 'entityId')))
                                          else r end order by ord), '[]'::jsonb)
           from jsonb_array_elements(c.card -> 'remember') with ordinality as t(r, ord))),
         updated_at = now()
   where c.user_id = p_uid and jsonb_typeof(c.card -> 'remember') = 'array'
     and exists (select 1 from jsonb_array_elements(c.card -> 'remember') r
                 where jsonb_typeof(r) = 'object' and v_map ? (r ->> 'entityId'));

  update public.notebooks nb
     set entity_count = (select count(*) from public.entities e where e.notebook_id = nb.id)
   where nb.id = any(v_touched);
  perform public._enqueue_embed(v_touched);
  return v_touched;
end;
$$;

-- An incoming change with every entity whose id spells a forgotten name
-- renamed (see _redact_id) and its id rewritten wherever the change uses it,
-- and each entity and relation once (the first wins). Old ids that changed
-- are listed under 'renamed', for the device to drop.
create function public._commit_redact_ids(p_uid uuid, p_change jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_change jsonb := p_change;
  v_map jsonb;
  v_rmap jsonb;
  v_field text;
begin
  -- By each incoming entity's name; ids elsewhere in the change follow.
  select coalesce(jsonb_object_agg(id, new_id), '{}') into v_map from (
    select distinct on (x.id) x.id, public._redact_id(p_uid, x.id, x.name) as new_id from (
      select value ->> 'id' as id, value ->> 'name' as name, ord
      from jsonb_array_elements(case when jsonb_typeof(p_change -> 'entities') = 'array'
                                     then p_change -> 'entities' else '[]'::jsonb end) with ordinality as t(value, ord)
    ) x where x.id is not null order by x.id, x.ord
  ) m where new_id <> id;
  select coalesce(jsonb_object_agg(id, new_id), '{}') into v_rmap from (
    select x.id, public._map_relation_id(x.id, v_map) as new_id from (
      select value ->> 'id' as id from jsonb_array_elements(coalesce(p_change -> 'relations', '[]'))
      union select jsonb_array_elements_text(coalesce(p_change -> 'entry' -> 'relationIds', '[]'))
    ) x where x.id is not null
  ) m where new_id <> id;
  if v_map = '{}'::jsonb and v_rmap = '{}'::jsonb then
    return p_change;
  end if;

  if jsonb_typeof(p_change -> 'entities') = 'array' then
    v_change := jsonb_set(v_change, '{entities}', coalesce((
      select jsonb_agg(v order by ord) from (
        select distinct on (coalesce(v_map ->> (value ->> 'id'), value ->> 'id'))
               case when v_map ? (value ->> 'id')
                    then jsonb_set(value, '{id}', to_jsonb(v_map ->> (value ->> 'id'))) else value end as v,
               ord
        from jsonb_array_elements(p_change -> 'entities') with ordinality as t(value, ord)
        order by coalesce(v_map ->> (value ->> 'id'), value ->> 'id'), ord
      ) d), '[]'::jsonb));
  end if;
  if jsonb_typeof(p_change -> 'relations') = 'array' then
    v_change := jsonb_set(v_change, '{relations}', coalesce((
      select jsonb_agg(v order by ord) from (
        select distinct on (coalesce(v_rmap ->> (value ->> 'id'), value ->> 'id'))
               value || jsonb_strip_nulls(jsonb_build_object(
                 'id', v_rmap ->> (value ->> 'id'),
                 'source', v_map ->> (value ->> 'source'),
                 'target', v_map ->> (value ->> 'target'))) as v,
               ord
        from jsonb_array_elements(p_change -> 'relations') with ordinality as t(value, ord)
        order by coalesce(v_rmap ->> (value ->> 'id'), value ->> 'id'), ord
      ) d), '[]'::jsonb));
  end if;
  if jsonb_typeof(p_change -> 'entry') = 'object' then
    if jsonb_typeof(p_change -> 'entry' -> 'entityIds') = 'array' then
      v_change := jsonb_set(v_change, '{entry,entityIds}', to_jsonb(public._map_ids(
        array(select jsonb_array_elements_text(p_change -> 'entry' -> 'entityIds')), v_map)));
    end if;
    if jsonb_typeof(p_change -> 'entry' -> 'relationIds') = 'array' then
      v_change := jsonb_set(v_change, '{entry,relationIds}', to_jsonb(public._map_ids(
        array(select jsonb_array_elements_text(p_change -> 'entry' -> 'relationIds')), v_rmap)));
    end if;
  end if;
  foreach v_field in array array['followUp', 'askedQuestion'] loop
    if jsonb_typeof(p_change -> v_field -> 'targetEntityIds') = 'array' then
      v_change := jsonb_set(v_change, array[v_field, 'targetEntityIds'], to_jsonb(public._map_ids(
        array(select jsonb_array_elements_text(p_change -> v_field -> 'targetEntityIds')), v_map)));
    end if;
  end loop;

  return v_change || jsonb_build_object('renamed', (
    select coalesce(jsonb_agg(k order by k), '[]') from jsonb_object_keys(v_map) k));
end;
$$;

-- The commit: ids first, then 20261104000900's redaction and suppression.
alter function public._commit_apply_turn(uuid, uuid, jsonb) rename to _commit_apply_turn_redacted;

create function public._commit_apply_turn(
  p_notebook_id uuid,
  p_uid uuid,
  p_change jsonb
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_change jsonb := p_change;
  v_renamed jsonb := '[]';
  v_result jsonb;
begin
  if exists (select 1 from public.entity_suppressions s
             where s.user_id = p_uid and s.kind = 'forgotten') then
    v_change := public._commit_redact_ids(p_uid, p_change);
    v_renamed := coalesce(v_change -> 'renamed', '[]');
    v_change := v_change - 'renamed';
  end if;
  v_result := public._commit_apply_turn_redacted(p_notebook_id, p_uid, v_change);
  -- The device dropped by id what it sent: renamed ids are gone under that
  -- id, like suppressed ones (commit_notebook keeps them out of the ledger).
  if jsonb_array_length(v_renamed) > 0 then
    v_result := v_result || jsonb_build_object('suppressedIds', (
      select jsonb_agg(distinct x) from (
        select jsonb_array_elements_text(coalesce(v_result -> 'suppressedIds', '[]')) as x
        union select jsonb_array_elements_text(v_renamed)) u));
  end if;
  return v_result;
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 3. Cards stay current when nothing they say changed
-- ────────────────────────────────────────────────────────────

-- Cards that were current at p_before ({notebook id: revision}) follow their
-- notebook's new revision, except one that remembers p_entity_id.
create function public._keep_cards_current(p_uid uuid, p_before jsonb, p_entity_id text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.session_cards c
     set source_revision = nb.revision,
         card = jsonb_set(c.card, '{sourceRevision}', to_jsonb(nb.revision)),
         updated_at = now()
    from public.notebooks nb
   where nb.id = c.notebook_id and c.user_id = p_uid
     and c.source_revision = (p_before ->> nb.id::text)::bigint
     and nb.revision <> c.source_revision
     and (p_entity_id is null or not exists (
           select 1 from jsonb_array_elements(case when jsonb_typeof(c.card -> 'remember') = 'array'
                                                   then c.card -> 'remember' else '[]'::jsonb end) r
           where r ->> 'entityId' = p_entity_id));
$$;

create function public._revisions(p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_object_agg(id::text, revision), '{}') from public.notebooks where user_id = p_uid;
$$;

alter function public.remove_entity(text) rename to _remove_entity_core;

create function public.remove_entity(p_entity_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_before jsonb;
  v_result jsonb;
begin
  -- The same lock order as commit_notebook and forget_entity, before the
  -- revisions are read.
  perform 1 from public.notebooks where user_id = v_uid order by id for update;
  v_before := public._revisions(v_uid);
  v_result := public._remove_entity_core(p_entity_id);
  perform public._keep_cards_current(v_uid, v_before, p_entity_id);
  return v_result;
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. forget_entity: 20261104000900's, then duplicates, ids and words
-- ────────────────────────────────────────────────────────────

-- Deletes the entity rows p_rows ([[notebook id, id], ...]) and what points
-- at them in their notebook: relations, provenance ids, question targets,
-- card remember items, embeddings. An id left in no notebook is suppressed as
-- removed, so it isn't added back. Returns the notebooks that changed.
create function public._drop_entity_rows(p_uid uuid, p_rows jsonb)
returns uuid[]
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_nb uuid;
  v_id text;
  v_rels text[];
  v_touched uuid[] := '{}';
begin
  for v_nb, v_id in
    select (r ->> 0)::uuid, r ->> 1 from jsonb_array_elements(p_rows) r
  loop
    with gone as (
      delete from public.relations x
       where x.user_id = p_uid and x.notebook_id = v_nb and v_id in (x.source_id, x.target_id)
      returning x.id
    )
    select coalesce(array_agg(id), '{}') into v_rels from gone;
    update public.journal_entries je
       set entity_ids = array_remove(je.entity_ids, v_id),
           relation_ids = array(select x from unnest(je.relation_ids) with ordinality as t(x, ord)
                                where not (x = any(v_rels)) order by ord)
     where je.user_id = p_uid and je.notebook_id = v_nb
       and (v_id = any(je.entity_ids) or je.relation_ids && v_rels);
    update public.follow_ups f set target_entity_ids = array_remove(f.target_entity_ids, v_id)
     where f.user_id = p_uid and f.notebook_id = v_nb and v_id = any(f.target_entity_ids);
    update public.asked_questions a set target_entity_ids = array_remove(a.target_entity_ids, v_id)
     where a.user_id = p_uid and a.notebook_id = v_nb and v_id = any(a.target_entity_ids);
    update public.session_cards c
       set card = jsonb_set(c.card, '{remember}', (
             select coalesce(jsonb_agg(r order by ord), '[]'::jsonb)
             from jsonb_array_elements(c.card -> 'remember') with ordinality as t(r, ord)
             where r ->> 'entityId' is distinct from v_id)),
           updated_at = now()
     where c.user_id = p_uid and c.notebook_id = v_nb and jsonb_typeof(c.card -> 'remember') = 'array';
    delete from public.entity_embeddings x
     where x.user_id = p_uid and x.notebook_id = v_nb and x.entity_id = v_id;
    delete from public.entities e where e.user_id = p_uid and e.notebook_id = v_nb and e.id = v_id;
    if not exists (select 1 from public.entities e where e.user_id = p_uid and e.id = v_id) then
      insert into public.entity_suppressions (user_id, entity_hash)
        values (p_uid, public._suppression_hash(p_uid, v_id))
        on conflict (user_id, entity_hash) do nothing;
    end if;
    v_touched := v_touched || v_nb;
  end loop;
  update public.notebooks nb
     set entity_count = (select count(*) from public.entities e where e.notebook_id = nb.id)
   where nb.id = any(v_touched);
  return v_touched;
end;
$$;

alter function public.forget_entity(text) rename to _forget_entity_core;

create function public.forget_entity(p_entity_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_slugs text[];
  v_key bytea := '\x00'::bytea;
  v_hashes text[];
  v_inside boolean;
  v_words int;
  v_dups jsonb;
  v_names jsonb;
  v_counts jsonb;
  v_mid jsonb;
  v_touched uuid[];
  v_more uuid[];
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;
  perform 1 from public.notebooks where user_id = v_uid order by id for update;

  -- The person under another id: a row whose whole name, or whole id, is
  -- theirs. Found before the forget renames them "someone".
  v_slugs := public._forget_slugs(v_uid, p_entity_id);
  v_inside := exists (select 1 from unnest(v_slugs) s where public._no_word_gaps(s));
  v_hashes := array(select encode(hmac(convert_to(s, 'UTF8'), v_key, 'sha256'), 'hex') from unnest(v_slugs) s);
  v_words := (select coalesce(max(public._slug_words(s)), 1) from unnest(v_slugs) s);
  select coalesce(jsonb_agg(jsonb_build_array(e.notebook_id, e.id)), '[]') into v_dups
    from public.entities e
   where e.user_id = v_uid and e.id <> p_entity_id
     and (public._redact_text(e.name, v_key, v_hashes, v_inside, v_words) = 'someone'
          or e.id = any(v_slugs));

  -- Names as they are now: the forget redacts them, and an id is judged by
  -- its entity's name.
  select coalesce(jsonb_object_agg(id, name), '{}') into v_names from (
    select distinct on (e.id) e.id, e.name from public.entities e
    where e.user_id = v_uid order by e.id, e.last_seen desc
  ) n;

  v_counts := public._forget_entity_core(p_entity_id);
  v_mid := public._revisions(v_uid);

  -- Their rows go, by notebook: the same id elsewhere can be someone else.
  -- Removed, not forgotten, since an id can be a plain word ("priya").
  v_touched := public._drop_entity_rows(v_uid, v_dups);
  v_more := public._forget_rename_ids(v_uid, v_names);
  v_touched := v_touched || v_more;

  -- What Lumen reads of the user's words. The trigger recomputes each row;
  -- only rows whose slugged text contains a slug of the person are touched.
  with done as (
    update public.journal_entries je set text = je.text
     where je.user_id = v_uid
       and exists (select 1 from unnest(v_slugs) s where position(s in public._slug_text(je.text)) > 0)
    returning je.notebook_id
  )
  select coalesce(array_agg(distinct notebook_id), '{}') into v_more from done;
  v_touched := v_touched || v_more;
  update public.conversation_turns ct set text = ct.text
   where ct.user_id = v_uid
     and exists (select 1 from unnest(v_slugs) s where position(s in public._slug_text(ct.text)) > 0);

  -- A device holding the old ids or words reloads. Cards that were current
  -- stay current: nothing they say changed here.
  update public.notebooks nb
     set revision = nb.revision + 1, updated_at = now()
   where nb.id = any(v_touched) and nb.revision = (v_mid ->> nb.id::text)::bigint;
  perform public._keep_cards_current(v_uid, v_mid, null);

  return v_counts;
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 5. Reads: Lumen's words come from context_text
-- ────────────────────────────────────────────────────────────

-- 20261021000000's, with the excerpt from context_text. The turn match still
-- compares the stored words.
create or replace function public.get_entity_mentions(
  p_entity_id text,
  p_limit int default 20,
  p_before timestamptz default null
) returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  with hits as (
    select je.id, je.notebook_id, je.text, je.context_text, je.created_at
    from public.journal_entries je
    where je.user_id = auth.uid()
      and je.entity_ids @> array[p_entity_id]
  ),
  page as (
    select h.*
    from hits h
    where p_before is null or h.created_at < p_before
    order by h.created_at desc, h.id desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  )
  select jsonb_build_object(
    'total', (select count(*) from hits),
    'mentions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entryId', p.id, 'notebookId', p.notebook_id,
        'notebookTitle', nb.title, 'notebookStartedAt', nb.started_at,
        'conversationMode', nb.conversation_mode,
        'createdAt', p.created_at, 'excerpt', left(coalesce(p.context_text, p.text), 280),
        'turnId', t.turn_id, 'spokenAt', t.spoken_at
      ) order by p.created_at desc, p.id desc)
      from page p
      join public.notebooks nb on nb.id = p.notebook_id
      left join lateral (
        select ct.turn_id, ct.spoken_at
        from public.conversation_turns ct
        where ct.notebook_id = p.notebook_id
          and ct.speaker = 'user'
          and ct.text = p.text
          and ct.spoken_at <= p.created_at
        order by ct.spoken_at desc
        limit 1
      ) t on true
    ), '[]'::jsonb)
  );
$$;

-- 20261104000300's, with each entry's text from context_text. The snapshot
-- is Lumen's state and the graph views', not the transcript view's.
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
    'state', jsonb_build_object(
      'entries', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', e.id, 'text', coalesce(e.context_text, e.text), 'createdAt', e.created_at,
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

revoke all on function public._context_text(uuid, text) from public, anon, authenticated;
revoke all on function public._set_context_text() from public, anon, authenticated;
revoke all on function public._slug_text(text) from public, anon, authenticated;
revoke all on function public._redact_id(uuid, text, text) from public, anon, authenticated;
revoke all on function public._map_relation_id(text, jsonb) from public, anon, authenticated;
revoke all on function public._enqueue_embed(uuid[]) from public, anon, authenticated;
revoke all on function public._map_ids(text[], jsonb) from public, anon, authenticated;
revoke all on function public._forget_rename_ids(uuid, jsonb) from public, anon, authenticated;
revoke all on function public._commit_redact_ids(uuid, jsonb) from public, anon, authenticated;
revoke all on function public._commit_apply_turn_redacted(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public._commit_apply_turn(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public._keep_cards_current(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public._revisions(uuid) from public, anon, authenticated;
revoke all on function public._remove_entity_core(text) from public, anon, authenticated;
revoke all on function public.remove_entity(text) from public, anon;
grant execute on function public.remove_entity(text) to authenticated;
revoke all on function public._drop_entity_rows(uuid, jsonb) from public, anon, authenticated;
revoke all on function public._forget_entity_core(text) from public, anon, authenticated;
revoke all on function public.forget_entity(text) from public, anon;
grant execute on function public.forget_entity(text) to authenticated;
