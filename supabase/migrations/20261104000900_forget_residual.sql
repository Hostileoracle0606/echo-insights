-- Residual Forget gaps from the re-review (R1, R2, R3, R6).
--
-- R1. The structural-key skip in _jsonb_redact_forgotten belongs to cards.
-- Metadata is free-form, so "type" or "id" there can hold a name:
-- _jsonb_redact_all redacts every string in it, keys included.
--
-- R2. Names of any length. A word run stopped at three, and a hyphen splits a
-- word, so "Jean-Claude Van Damme" never matched. entity_suppressions.name_words
-- bounds the run by the user's longest forgotten name. It reveals only a word
-- count. Existing rows keep the old limit of 3.
--
-- R3. Clients don't slug alike: Dart keeps й and Hangul composed and splits at
-- ễ, while the web and SQL decompose. So an id can differ from the id a person
-- was forgotten under, and the person came back with a readable id and the name
-- "someone". The commit now also checks each incoming entity's name slug; a
-- match suppresses that id too, under the same kind.
--
-- R6. Forget bumps a notebook's revision. A card that was current then stays
-- current even when it doesn't mention the person, so it isn't regenerated.

alter table public.entity_suppressions
  add column name_words smallint not null default 3;

comment on column public.entity_suppressions.name_words is
  'Words in the forgotten name: how long a run of words redaction must try.';

-- Words in a slug, which is also the words a name splits into in text.
create or replace function public._slug_words(p_slug text)
returns int
language sql
immutable
as $$
  select cardinality(array_remove(string_to_array(p_slug, '-'), ''));
$$;

drop function public._redact_text(text, bytea, text[], boolean);
drop function public._forget_mentions(jsonb, bytea, text[], boolean, text);

-- p_text with any run of up to p_max_words words whose slug hashes to p_hashes
-- replaced by "someone". The matcher behind redact_forgotten and the preview.
create function public._redact_text(
  p_text text, p_key bytea, p_hashes text[], p_inside boolean, p_max_words int
) returns text
language plpgsql
stable
set search_path = public, extensions, pg_temp
as $$
declare
  v_toks text[];
  v_word boolean[];
  v_n int;
  v_i int := 1;
  v_run int;
  v_len int;
  v_k int;
  v_first text;
  v_slug text;
  v_hit boolean;
begin
  if p_text is null or p_text = '' or cardinality(p_hashes) = 0 then
    return p_text;
  end if;

  -- Alternating words and the gaps between them, in order.
  select array_agg(coalesce(t.r[1], t.r[2]) order by t.ord),
         array_agg(t.r[1] is not null order by t.ord)
    into v_toks, v_word
    from regexp_matches(p_text, '([^\u0001-/:-@[-`{-¿×÷։־׃،؛؟۔।॥ -⯿　-〿︀-️︰-﹯！-／：-＠［-｀｛-･\U0001f000-\U0001faff]+)|([\u0001-/:-@[-`{-¿×÷։־׃،؛؟۔।॥ -⯿　-〿︀-️︰-﹯！-／：-＠［-｀｛-･\U0001f000-\U0001faff]+)', 'g') with ordinality as t(r, ord);
  v_n := cardinality(v_toks);

  while v_i <= v_n loop
    v_hit := false;
    if v_word[v_i] then
      -- How far a name could reach from here: words joined by spaces, hyphens,
      -- apostrophes or periods (O'Brien, St. John). A comma, newline or other
      -- sentence punctuation ends a name.
      v_run := 1;
      while v_run < p_max_words
            and v_i + 2 * v_run <= v_n
            and v_word[v_i + 2 * v_run]
            and v_toks[v_i + 2 * v_run - 1] ~ '^[ \t''’.-]+$' loop
        v_run := v_run + 1;
      end loop;

      -- Longest run first.
      for v_len in reverse v_run..1 loop
        v_k := v_i + 2 * (v_len - 1);
        if v_len = 1 then
          -- One word: only as a name, so never a lowercase "will". A script
          -- with no case passes, since upper() leaves it alone.
          v_first := left(v_toks[v_i], 1);
          continue when v_first <> upper(v_first);
        end if;
        v_slug := public._slugify(array_to_string(v_toks[v_i:v_k], ''));
        continue when v_slug = '';
        if encode(hmac(convert_to(v_slug, 'UTF8'), p_key, 'sha256'), 'hex') = any(p_hashes) then
          v_toks[v_i] := 'someone';
          for g in v_i + 1 .. v_k loop
            v_toks[g] := '';
          end loop;
          v_i := v_k + 1;
          v_hit := true;
          exit;
        end if;
      end loop;
      if not v_hit and p_inside and public._no_word_gaps(v_toks[v_i]) then
        v_toks[v_i] := public._redact_inside_word(v_toks[v_i], p_key, p_hashes);
      end if;
    end if;
    if not v_hit then
      v_i := v_i + 1;
    end if;
  end loop;

  return array_to_string(v_toks, '');
end;
$$;

create or replace function public.redact_forgotten(p_uid uuid, p_text text)
returns text
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_key bytea;
  v_hashes text[];
  v_inside boolean;
  v_words int;
begin
  if p_text is null or p_text = '' then
    return p_text;
  end if;
  select k.key into v_key from public.suppression_keys k where k.user_id = p_uid;
  if v_key is null then
    return p_text;
  end if;
  select coalesce(array_agg(s.entity_hash), '{}'), coalesce(bool_or(s.match_inside), false),
         coalesce(max(s.name_words), 1)
    into v_hashes, v_inside, v_words
    from public.entity_suppressions s
    where s.user_id = p_uid and s.kind = 'forgotten';
  return public._redact_text(p_text, v_key, v_hashes, v_inside, v_words);
end;
$$;

-- Every string in free-form JSON, keys too: nothing in it is structural.
create or replace function public._jsonb_redact_all(p_uid uuid, p_json jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  case jsonb_typeof(p_json)
    when 'string' then
      return to_jsonb(public.redact_forgotten(p_uid, p_json #>> '{}'));
    when 'array' then
      return coalesce((
        select jsonb_agg(public._jsonb_redact_all(p_uid, v) order by ord)
        from jsonb_array_elements(p_json) with ordinality as t(v, ord)
      ), '[]'::jsonb);
    when 'object' then
      return coalesce((
        select jsonb_object_agg(public.redact_forgotten(p_uid, k), public._jsonb_redact_all(p_uid, v))
        from jsonb_each(p_json) as t(k, v)
      ), '{}'::jsonb);
    else
      return p_json;
  end case;
end;
$$;

-- True when a string in p_json names the person or equals the id.
create function public._forget_mentions(
  p_json jsonb, p_key bytea, p_hashes text[], p_inside boolean, p_max_words int, p_entity_id text
) returns boolean
language sql
stable
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from jsonb_path_query(p_json, 'strict $.**') v
    where jsonb_typeof(v) = 'string'
      and ((v #>> '{}') = p_entity_id
           or public._redact_text(v #>> '{}', p_key, p_hashes, p_inside, p_max_words) <> (v #>> '{}'))
  );
$$;

create or replace function public._forget_counts(p_uid uuid, p_entity_id text, p_slugs text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_key bytea := '\x00'::bytea;
  v_inside boolean := exists (select 1 from unnest(p_slugs) s where public._no_word_gaps(s));
  v_hashes text[] := array(select encode(hmac(convert_to(s, 'UTF8'), '\x00'::bytea, 'sha256'), 'hex')
                           from unnest(p_slugs) s);
  v_words int := (select coalesce(max(public._slug_words(s)), 1) from unnest(p_slugs) s);
begin
  return jsonb_build_object(
    'notebooks', (select count(distinct e.notebook_id) from public.entities e
                  where e.user_id = p_uid and e.id = p_entity_id),
    'relations', (select count(*) from public.relations r
                  where r.user_id = p_uid and p_entity_id in (r.source_id, r.target_id)),
    'followUps', (select count(*) from public.follow_ups f
                  where f.user_id = p_uid
                    and (p_entity_id = any(f.target_entity_ids)
                         or public._redact_text(f.question, v_key, v_hashes, v_inside, v_words) <> f.question
                         or public._redact_text(f.reason, v_key, v_hashes, v_inside, v_words) <> f.reason)),
    'askedQuestions', (select count(*) from public.asked_questions a
                       where a.user_id = p_uid
                         and (p_entity_id = any(a.target_entity_ids)
                              or public._redact_text(a.question, v_key, v_hashes, v_inside, v_words) <> a.question)),
    'cards', (select count(*) from public.session_cards c
              where c.user_id = p_uid
                and public._forget_mentions(c.card - 'conversationMode', v_key, v_hashes, v_inside, v_words, p_entity_id)),
    'briefDeleted', exists (select 1 from public.session_briefs b
                            where b.user_id = p_uid
                              and public._forget_mentions(b.brief, v_key, v_hashes, v_inside, v_words, p_entity_id))
  );
end;
$$;

create or replace function public.forget_entity(p_entity_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_slugs text[];
  v_counts jsonb;
  v_before jsonb;
  v_touched uuid[];
  v_more uuid[];
  v_key bytea := '\x00'::bytea;
  v_hashes text[];
  v_inside boolean;
  v_words int;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;

  -- Every notebook of the caller's, in id order (commit_notebook's lock
  -- order), so nothing here races a commit.
  perform 1 from public.notebooks where user_id = v_uid order by id for update;
  select coalesce(jsonb_object_agg(id::text, revision), '{}') into v_before
    from public.notebooks where user_id = v_uid;

  v_slugs := public._forget_slugs(v_uid, p_entity_id);
  v_counts := public._forget_counts(v_uid, p_entity_id, v_slugs);
  v_inside := exists (select 1 from unnest(v_slugs) s where public._no_word_gaps(s));
  v_hashes := array(select encode(hmac(convert_to(s, 'UTF8'), v_key, 'sha256'), 'hex') from unnest(v_slugs) s);
  v_words := (select coalesce(max(public._slug_words(s)), 1) from unnest(v_slugs) s);

  -- First, so everything below redacts through the same matcher. A person who
  -- was only removed before becomes forgotten here.
  insert into public.entity_suppressions (user_id, entity_hash, kind, match_inside, name_words)
    select v_uid, public._suppression_hash(v_uid, s), 'forgotten', public._no_word_gaps(s), public._slug_words(s)
    from unnest(v_slugs) s
    on conflict (user_id, entity_hash) do update
      set kind = 'forgotten', match_inside = excluded.match_inside, name_words = excluded.name_words;

  -- Questions about the person go whole (remove_entity only strips the id).
  delete from public.follow_ups
    where user_id = v_uid
      and (p_entity_id = any(target_entity_ids)
           or public.redact_forgotten(v_uid, question) <> question
           or public.redact_forgotten(v_uid, reason) <> reason);
  delete from public.asked_questions
    where user_id = v_uid
      and (p_entity_id = any(target_entity_ids)
           or public.redact_forgotten(v_uid, question) <> question);

  -- Other entities can name the person: agenda questions and retrieval read
  -- these back to Gemini. A changed entity's embedding goes too (it is made
  -- from this text); embed-entities makes a new one.
  with next as (
    select e.notebook_id, e.id,
           public.redact_forgotten(v_uid, e.name) as name,
           public.redact_forgotten(v_uid, e.description) as description,
           public._jsonb_redact_all(v_uid, e.metadata) as metadata,
           case when e.questions is null then null else array(
             select public.redact_forgotten(v_uid, q)
             from unnest(e.questions) with ordinality as t(q, ord) order by ord) end as questions
      from public.entities e
     where e.user_id = v_uid and e.id <> p_entity_id
  ), changed as (
    update public.entities e
       set name = n.name, description = n.description, metadata = n.metadata, questions = n.questions
      from next n
     where e.notebook_id = n.notebook_id and e.id = n.id
       and (e.name, e.description, e.metadata, e.questions)
           is distinct from (n.name, n.description, n.metadata, n.questions)
    returning e.notebook_id, e.id
  ), embeddings as (
    delete from public.entity_embeddings x using changed c
     where x.notebook_id = c.notebook_id and x.entity_id = c.id
    returning 1
  )
  select coalesce(array_agg(distinct notebook_id), '{}') into v_touched from changed;

  with changed as (
    update public.relations r
       set metadata = public._jsonb_redact_all(v_uid, r.metadata)
     where r.user_id = v_uid
       and r.metadata is distinct from public._jsonb_redact_all(v_uid, r.metadata)
    returning r.notebook_id
  )
  select coalesce(array_agg(distinct notebook_id), '{}') into v_more from changed;
  v_touched := v_touched || v_more;

  -- The entity, relations, embeddings and provenance ids, and the revision
  -- bump where the graph lost something.
  perform public.remove_entity(p_entity_id);

  -- A notebook that only had text redacted changed too: a device must reload.
  update public.notebooks nb
     set revision = nb.revision + 1, updated_at = now()
   where nb.id = any(v_touched) and nb.revision = (v_before ->> nb.id::text)::bigint;

  -- A brief that mentions the person is deleted (its audio goes with it).
  delete from public.session_briefs b
    where b.user_id = v_uid
      and public._forget_mentions(b.brief, v_key, v_hashes, v_inside, v_words, p_entity_id);

  -- Cards are redacted, not regenerated. A card that was current stays current
  -- for the notebook's new revision, so it isn't regenerated for being stale.
  with next as (
    select c.notebook_id, public._jsonb_redact_forgotten(v_uid, c.card) as card
      from public.session_cards c where c.user_id = v_uid
  )
  update public.session_cards c
     set card = case when c.source_revision = (v_before ->> nb.id::text)::bigint
                          and nb.revision <> c.source_revision
                     then jsonb_set(n.card, '{sourceRevision}', to_jsonb(nb.revision))
                     else n.card end,
         source_revision = case when c.source_revision = (v_before ->> nb.id::text)::bigint
                                then nb.revision else c.source_revision end,
         updated_at = now()
    from next n, public.notebooks nb
   where n.notebook_id = c.notebook_id and nb.id = c.notebook_id
     and (n.card is distinct from c.card
          or public._forget_mentions(c.card - 'conversationMode', v_key, v_hashes, v_inside, v_words, p_entity_id)
          -- R6: the notebook moved on because of the forget, not because the
          -- conversation did, so a card that was current still is.
          or (c.source_revision = (v_before ->> nb.id::text)::bigint and nb.revision <> c.source_revision));

  update public.notebooks
     set title = public.redact_forgotten(v_uid, title),
         summary = public.redact_forgotten(v_uid, summary)
   where user_id = v_uid
     and (title is distinct from public.redact_forgotten(v_uid, title)
          or summary is distinct from public.redact_forgotten(v_uid, summary));

  return v_counts;
end;
$$;

-- An incoming entity with its free text redacted. Its id and type stay.
create or replace function public._commit_redact_entity(p_uid uuid, p_entity jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_out jsonb := p_entity;
  v_field text;
begin
  if jsonb_typeof(p_entity) is distinct from 'object' then
    return p_entity;
  end if;
  foreach v_field in array array['name', 'description', 'metadata', 'questions'] loop
    if p_entity ? v_field then
      v_out := v_out || jsonb_build_object(v_field, public._jsonb_redact_all(p_uid, p_entity->v_field));
    end if;
  end loop;
  return v_out;
end;
$$;

create or replace function public._commit_apply_turn(
  p_notebook_id uuid,
  p_uid uuid,
  p_change jsonb
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_change jsonb := p_change;
  v_entities jsonb := coalesce(p_change->'entities', '[]'::jsonb);
  v_relations jsonb := coalesce(p_change->'relations', '[]'::jsonb);
  v_entry jsonb := p_change->'entry';
  v_ids text[];
  v_suppressed text[];
  v_forgotten text[];
  v_field text;
  v_part jsonb;
  v_targets text[];
  v_result jsonb;
begin
  v_ids := array(
    select x from (
      select value->>'id' as x from jsonb_array_elements(v_entities)
      union select value->>'source' from jsonb_array_elements(v_relations)
      union select value->>'target' from jsonb_array_elements(v_relations)
      union select jsonb_array_elements_text(coalesce(v_entry->'entityIds', '[]'::jsonb))
    ) c where x is not null);

  -- R3: the same person under another client's id. Suppressing that id here
  -- lets the commit drop them, their relations and their ids the usual way.
  if exists (select 1 from public.entity_suppressions s where s.user_id = p_uid) then
    insert into public.entity_suppressions (user_id, entity_hash, kind, match_inside, name_words)
      select p_uid, public._suppression_hash(p_uid, e.id), s.kind, s.match_inside, s.name_words
      from (
        select distinct value->>'id' as id, public._slugify(value->>'name') as slug
        from jsonb_array_elements(v_entities)
      ) e
      join public.entity_suppressions s
        on s.user_id = p_uid and s.entity_hash = public._suppression_hash(p_uid, e.slug)
      where e.id is not null and e.slug <> '' and e.id <> e.slug
      on conflict (user_id, entity_hash) do update
        set kind = case when excluded.kind = 'forgotten' then 'forgotten'
                        else public.entity_suppressions.kind end;
  end if;

  v_suppressed := public._suppressed_ids(p_uid, v_ids);

  if exists (select 1 from public.entity_suppressions s
             where s.user_id = p_uid and s.kind = 'forgotten') then
    foreach v_field in array array['followUp', 'askedQuestion'] loop
      v_part := p_change->v_field;
      continue when jsonb_typeof(v_part) is distinct from 'object';
      v_targets := case when jsonb_typeof(v_part->'targetEntityIds') = 'array'
                        then array(select jsonb_array_elements_text(v_part->'targetEntityIds'))
                        else '{}' end;
      if cardinality(public._forgotten_ids(p_uid, v_targets)) > 0
         or public._json_mentions_forgotten(p_uid, v_part) then
        v_change := v_change - v_field;
      end if;
    end loop;

    if jsonb_typeof(v_entities) = 'array' then
      v_change := v_change || jsonb_build_object('entities', coalesce((
        select jsonb_agg(public._commit_redact_entity(p_uid, value) order by ord)
        from jsonb_array_elements(v_entities) with ordinality as t(value, ord)
      ), '[]'::jsonb));
    end if;
    if jsonb_typeof(v_relations) = 'array' then
      v_change := v_change || jsonb_build_object('relations', coalesce((
        select jsonb_agg(case when value ? 'metadata'
                              then jsonb_set(value, '{metadata}',
                                             public._jsonb_redact_all(p_uid, value->'metadata'))
                              else value end order by ord)
        from jsonb_array_elements(v_relations) with ordinality as t(value, ord)
      ), '[]'::jsonb));
    end if;
  end if;

  v_result := public._commit_apply_turn_core(p_notebook_id, p_uid, v_change);
  if cardinality(v_suppressed) > 0 then
    v_result := v_result || jsonb_build_object('suppressedIds', to_jsonb(v_suppressed));
  end if;
  return v_result;
end;
$$;

revoke all on function public._slug_words(text) from public, anon, authenticated;
revoke all on function public._redact_text(text, bytea, text[], boolean, int) from public, anon, authenticated;
revoke all on function public.redact_forgotten(uuid, text) from public, anon, authenticated;
revoke all on function public._jsonb_redact_all(uuid, jsonb) from public, anon, authenticated;
revoke all on function public._forget_mentions(jsonb, bytea, text[], boolean, int, text) from public, anon, authenticated;
revoke all on function public._forget_counts(uuid, text, text[]) from public, anon, authenticated;
revoke all on function public._commit_redact_entity(uuid, jsonb) from public, anon, authenticated;
revoke all on function public._commit_apply_turn(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.forget_entity(text) from public, anon;
grant execute on function public.forget_entity(text) to authenticated;
