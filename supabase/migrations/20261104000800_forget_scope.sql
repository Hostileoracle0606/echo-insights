-- Forget means forget, and only forget (final review C1, C2, I3, I4, M2, M4, M6).
--
-- C1. Text redaction used to read every suppression, so a plain Remove of
-- "work" rewrote the word "work" in cards, and could corrupt structural values
-- such as conversationMode. Now:
--   * entity_suppressions.kind: 'removed' (remove_entity; existing rows) or
--     'forgotten' (only forget_entity). Redaction reads 'forgotten' alone.
--     Removed ids are still kept out of the graph on commit.
--   * A single-word name matches only when capitalized in the source, so
--     forgetting Will, May or Mark leaves "will", "may" and "mark" alone. A
--     sentence that opens with the word is still redacted: that is the
--     privacy-safe direction, and text alone can't tell the two apart.
--   * Structural JSON keys are never rewritten.
--   * forget_entity uses this one matcher too, not a case-insensitive regex.
--
-- C2. The name no longer survives in text Lumen reads back. On commit, a
-- follow-up or asked question naming a forgotten person is dropped, and entity
-- names, descriptions, metadata, questions and relation metadata are redacted.
-- forget_entity does the same to the user's existing rows.
--
-- I3. Names with no Latin letters. _slugify keeps other scripts (same rule as
-- slugify() in lib/logic/slugify.dart and src/lib/journal-store.ts, whose ids
-- for Latin names do not change), and forget_entity hashes each name's slug as
-- well as the id, so an older random `e-<millis>` id still redacts. Words are
-- split on an explicit list of gaps because [[:alnum:]] breaks Devanagari at
-- its combining marks. Scripts written without spaces (Chinese, Japanese,
-- Thai) and Korean, which attaches particles, are also searched inside each
-- word, only for a user who has forgotten such a name (match_inside).
--
-- I4. commit_notebook tells the device which ids it dropped (suppressedIds),
-- in the response only: a readable slug is never stored in the commit ledger.
--
-- The transcripts themselves still keep the name (R10).

alter table public.entity_suppressions
  add column kind text not null default 'removed'
    constraint entity_suppressions_kind_check check (kind in ('removed', 'forgotten')),
  add column match_inside boolean not null default false;

comment on column public.entity_suppressions.kind is
  'removed: kept out of the graph. forgotten: also redacted from text.';
comment on column public.entity_suppressions.match_inside is
  'The name is in a script written without spaces, so look inside words.';

-- ────────────────────────────────────────────────────────────
-- The slug, and the word matcher
-- ────────────────────────────────────────────────────────────
create or replace function public._slugify(p_text text)
returns text
language sql
immutable
as $$
  select left(btrim(regexp_replace(
    regexp_replace(normalize(lower(coalesce(p_text, '')), NFKD), '[̀-ͯ]', '', 'g'),
    '[\u0001-/:-@[-`{-¿×÷։־׃،؛؟۔।॥ -⯿　-〿︀-️︰-﹯！-／：-＠［-｀｛-･\U0001f000-\U0001faffÀ-˿Ḁ-ỿⱠ-Ɀ꜠-ꟿ]+', '-', 'g'), '-'), 60);
$$;

-- Scripts whose words don't end where a name ends.
create or replace function public._no_word_gaps(p_text text)
returns boolean
language sql
immutable
as $$
  select p_text ~ '[฀-๿ᄀ-ᇿ぀-ヿ㐀-鿿가-힣豈-﫿]';
$$;

-- p_word with any 2-8 character run that hashes to p_hashes replaced.
create or replace function public._redact_inside_word(p_word text, p_key bytea, p_hashes text[])
returns text
language plpgsql
stable
set search_path = public, extensions, pg_temp
as $$
declare
  v_out text := '';
  v_i int := 1;
  v_n int := char_length(p_word);
  v_len int;
  v_hit boolean;
begin
  while v_i <= v_n loop
    v_hit := false;
    for v_len in reverse least(8, v_n - v_i + 1)..2 loop
      if encode(hmac(convert_to(public._slugify(substr(p_word, v_i, v_len)), 'UTF8'), p_key, 'sha256'), 'hex')
         = any(p_hashes) then
        v_out := v_out || 'someone';
        v_i := v_i + v_len;
        v_hit := true;
        exit;
      end if;
    end loop;
    if not v_hit then
      v_out := v_out || substr(p_word, v_i, 1);
      v_i := v_i + 1;
    end if;
  end loop;
  return v_out;
end;
$$;

-- p_text with any 1-3 word run whose slug hashes to p_hashes replaced by
-- "someone". The matcher behind redact_forgotten and the forget preview.
create or replace function public._redact_text(p_text text, p_key bytea, p_hashes text[], p_inside boolean)
returns text
language plpgsql
stable
set search_path = public, extensions, pg_temp
as $$
declare
  v_toks text[];
  v_word boolean[];
  v_n int;
  v_i int := 1;
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
      -- Longest run first: up to three words joined by spaces, hyphens,
      -- apostrophes or periods (O'Brien, St. John); a comma, newline or
      -- other sentence punctuation ends a name.
      for v_len in reverse 3..1 loop
        v_k := v_i + 2 * (v_len - 1);
        continue when v_k > v_n;
        if v_len = 1 then
          -- One word: only as a name, so never a lowercase "will". A script
          -- with no case passes, since upper() leaves it alone.
          v_first := left(v_toks[v_i], 1);
          continue when v_first <> upper(v_first);
          v_slug := public._slugify(v_toks[v_i]);
        else
          continue when not v_word[v_k] or v_toks[v_i + 1] !~ '^[ \t''’.-]+$';
          if v_len = 2 then
            v_slug := public._slugify(v_toks[v_i] || ' ' || v_toks[v_k]);
          else
            continue when not v_word[v_i + 2] or v_toks[v_i + 3] !~ '^[ \t''’.-]+$';
            v_slug := public._slugify(v_toks[v_i] || ' ' || v_toks[v_i + 2] || ' ' || v_toks[v_k]);
          end if;
        end if;
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
begin
  if p_text is null or p_text = '' then
    return p_text;
  end if;
  select k.key into v_key from public.suppression_keys k where k.user_id = p_uid;
  if v_key is null then
    return p_text;
  end if;
  select coalesce(array_agg(s.entity_hash), '{}'), coalesce(bool_or(s.match_inside), false)
    into v_hashes, v_inside
    from public.entity_suppressions s
    where s.user_id = p_uid and s.kind = 'forgotten';
  return public._redact_text(p_text, v_key, v_hashes, v_inside);
end;
$$;

-- The client/Lambda entry point. 2 MiB, as LM-46's audio cap: well over any
-- transcript sent to it, and enough to keep the tokenizer's work bounded.
create or replace function public.redact_forgotten_text(p_text text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if octet_length(coalesce(p_text, '')) > 2097152 then
    raise exception 'text is too large (max 2097152 bytes)' using errcode = '22023';
  end if;
  return public.redact_forgotten(auth.uid(), p_text);
end;
$$;

-- p_json with every string value redacted. Structural keys are left alone, as
-- are uuids and dates; objects naming a suppressed entity (an "entityId") are
-- dropped from their array.
create or replace function public._jsonb_redact_forgotten(p_uid uuid, p_json jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  case jsonb_typeof(p_json)
    when 'string' then
      if (p_json #>> '{}') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         or (p_json #>> '{}') ~ '^\d{4}-\d{2}-\d{2}([T ][0-9:.+Z-]*)?$' then
        return p_json;
      end if;
      return to_jsonb(public.redact_forgotten(p_uid, p_json #>> '{}'));
    when 'array' then
      return coalesce((
        select jsonb_agg(public._jsonb_redact_forgotten(p_uid, v) order by ord)
        from jsonb_array_elements(p_json) with ordinality as t(v, ord)
        where not (jsonb_typeof(v) = 'object' and jsonb_typeof(v -> 'entityId') = 'string'
                   and cardinality(public._suppressed_ids(p_uid, array[v ->> 'entityId'])) > 0)
      ), '[]'::jsonb);
    when 'object' then
      return coalesce((
        select jsonb_object_agg(k,
          case when k in ('id', 'type', 'kind', 'mode', 'version', 'entityId', 'notebookId',
                          'conversationMode', 'sourceRevision', 'generatedAt', 'descriptionSource')
               then v
               else public._jsonb_redact_forgotten(p_uid, v) end)
        from jsonb_each(p_json) as t(k, v)
      ), '{}'::jsonb);
    else
      return p_json;
  end case;
end;
$$;

-- ────────────────────────────────────────────────────────────
-- Preview and forget share these, so the counts match what is done.
-- ────────────────────────────────────────────────────────────

-- Every slug the person goes by: the id, and each name's slug. They differ
-- for an older random id, and across a client's slug rule.
create or replace function public._forget_slugs(p_uid uuid, p_entity_id text)
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(distinct s), '{}') from (
    select p_entity_id as s
    union select public._slugify(e.name) from public.entities e
      where e.user_id = p_uid and e.id = p_entity_id
  ) slugs where s <> '';
$$;

-- True when a string in p_json names the person or equals the id.
create or replace function public._forget_mentions(
  p_json jsonb, p_key bytea, p_hashes text[], p_inside boolean, p_entity_id text
) returns boolean
language sql
stable
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from jsonb_path_query(p_json, 'strict $.**') v
    where jsonb_typeof(v) = 'string'
      and ((v #>> '{}') = p_entity_id
           or public._redact_text(v #>> '{}', p_key, p_hashes, p_inside) <> (v #>> '{}'))
  );
$$;

drop function public._forget_counts(uuid, text, text);

-- The key is local to this call, for comparing within it: nothing is stored.
create function public._forget_counts(p_uid uuid, p_entity_id text, p_slugs text[])
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
begin
  return jsonb_build_object(
    'notebooks', (select count(distinct e.notebook_id) from public.entities e
                  where e.user_id = p_uid and e.id = p_entity_id),
    'relations', (select count(*) from public.relations r
                  where r.user_id = p_uid and p_entity_id in (r.source_id, r.target_id)),
    'followUps', (select count(*) from public.follow_ups f
                  where f.user_id = p_uid
                    and (p_entity_id = any(f.target_entity_ids)
                         or public._redact_text(f.question, v_key, v_hashes, v_inside) <> f.question
                         or public._redact_text(f.reason, v_key, v_hashes, v_inside) <> f.reason)),
    'askedQuestions', (select count(*) from public.asked_questions a
                       where a.user_id = p_uid
                         and (p_entity_id = any(a.target_entity_ids)
                              or public._redact_text(a.question, v_key, v_hashes, v_inside) <> a.question)),
    'cards', (select count(*) from public.session_cards c
              where c.user_id = p_uid
                and public._forget_mentions(c.card - 'conversationMode', v_key, v_hashes, v_inside, p_entity_id)),
    'briefDeleted', exists (select 1 from public.session_briefs b
                            where b.user_id = p_uid
                              and public._forget_mentions(b.brief, v_key, v_hashes, v_inside, p_entity_id))
  );
end;
$$;

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
  return public._forget_counts(v_uid, p_entity_id, public._forget_slugs(v_uid, p_entity_id));
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

  -- First, so everything below redacts through the same matcher. A person who
  -- was only removed before becomes forgotten here.
  insert into public.entity_suppressions (user_id, entity_hash, kind, match_inside)
    select v_uid, public._suppression_hash(v_uid, s), 'forgotten', public._no_word_gaps(s)
    from unnest(v_slugs) s
    on conflict (user_id, entity_hash) do update
      set kind = 'forgotten', match_inside = excluded.match_inside;

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
           public._jsonb_redact_forgotten(v_uid, e.metadata) as metadata,
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
       set metadata = public._jsonb_redact_forgotten(v_uid, r.metadata)
     where r.user_id = v_uid
       and r.metadata is distinct from public._jsonb_redact_forgotten(v_uid, r.metadata)
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
      and public._forget_mentions(b.brief, v_key, v_hashes, v_inside, p_entity_id);

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
          or public._forget_mentions(c.card - 'conversationMode', v_key, v_hashes, v_inside, p_entity_id));

  update public.notebooks
     set title = public.redact_forgotten(v_uid, title),
         summary = public.redact_forgotten(v_uid, summary)
   where user_id = v_uid
     and (title is distinct from public.redact_forgotten(v_uid, title)
          or summary is distinct from public.redact_forgotten(v_uid, summary));

  return v_counts;
end;
$$;

-- ────────────────────────────────────────────────────────────
-- Commit: the change is cleaned first, then applied by the same body as before
-- ────────────────────────────────────────────────────────────

-- The ids among p_ids that are forgotten, not merely removed.
create or replace function public._forgotten_ids(p_uid uuid, p_ids text[])
returns text[]
language plpgsql
stable
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
      where s.user_id = p_uid and s.kind = 'forgotten'
        and s.entity_hash = encode(hmac(convert_to(ids.x, 'UTF8'), v_key, 'sha256'), 'hex'))
  ), '{}');
end;
$$;

alter function public._commit_apply_turn(uuid, uuid, jsonb) rename to _commit_apply_turn_core;

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
        select jsonb_agg(public._jsonb_redact_forgotten(p_uid, value) order by ord)
        from jsonb_array_elements(v_entities) with ordinality as t(value, ord)
      ), '[]'::jsonb));
    end if;
    if jsonb_typeof(v_relations) = 'array' then
      v_change := v_change || jsonb_build_object('relations', coalesce((
        select jsonb_agg(case when value ? 'metadata'
                              then jsonb_set(value, '{metadata}',
                                             public._jsonb_redact_forgotten(p_uid, value->'metadata'))
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

revoke all on function public._commit_apply_turn_core(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public._commit_apply_turn(uuid, uuid, jsonb) from public, anon, authenticated;

-- 20261104000000's commit_notebook, except that suppressedIds stays out of the
-- stored result. A replayed commit doesn't carry it; the next snapshot does
-- the same job.
create or replace function public.commit_notebook(
  p_notebook_id uuid,
  p_expected_revision bigint,
  p_request_id uuid,
  p_change jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_notebook record;
  v_request_hash text;
  v_existing record;
  v_kind text;
  v_result jsonb;
  v_new_revision bigint;
  v_entity_count integer;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  -- Lock first: every other check below reads a value that could otherwise
  -- change out from under a concurrent commit to the same notebook.
  select * into v_notebook
    from public.notebooks
    where id = p_notebook_id and user_id = v_uid
    for update;

  if not found then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  -- LM-46: size and type caps, before anything is hashed or stored. A
  -- violation is returned as data (invalidChange), like any other invalid
  -- change: the client treats a thrown error as an unknown outcome and
  -- resends the same commit forever.
  begin
    perform public._commit_check_caps(p_change);
  exception when others then
    return jsonb_build_object('status', 'rejected', 'code', 'invalidChange');
  end;

  v_request_hash := md5(
    jsonb_build_object('change', p_change, 'expectedRevision', p_expected_revision)::text
  );

  select * into v_existing
    from public.notebook_commit_requests
    where notebook_id = p_notebook_id and request_id = p_request_id;

  if found then
    if v_existing.request_hash = v_request_hash then
      return v_existing.result; -- exact retry: hand back the prior outcome verbatim
    else
      return jsonb_build_object('status', 'rejected', 'code', 'requestIdReused');
    end if;
  end if;

  if p_expected_revision is distinct from v_notebook.revision then
    return jsonb_build_object('status', 'conflict', 'currentRevision', v_notebook.revision);
  end if;

  v_kind := p_change->>'kind';

  begin
    if v_kind = 'applyTurn' then
      v_result := public._commit_apply_turn(p_notebook_id, v_uid, p_change);
    elsif v_kind = 'answerFollowUp' then
      v_result := public._commit_answer_follow_up(p_notebook_id, p_change);
    elsif v_kind = 'clearNotebook' then
      v_result := public._commit_clear_notebook(p_notebook_id);
    else
      raise exception 'invalidChange: unknown kind %', coalesce(v_kind, '<null>');
    end if;
  exception
    when others then
      if sqlerrm like 'invalidChange:%' then
        return jsonb_build_object('status', 'rejected', 'code', 'invalidChange');
      end if;
      return jsonb_build_object('status', 'rejected', 'code', 'commitFailed');
  end;

  select count(*) into v_entity_count from public.entities where notebook_id = p_notebook_id;

  update public.notebooks
    set revision = revision + 1,
        updated_at = now(),
        entity_count = v_entity_count
    where id = p_notebook_id
    returning revision into v_new_revision;

  v_result := v_result
    || jsonb_build_object('status', 'committed', 'requestId', p_request_id, 'revision', v_new_revision);

  insert into public.notebook_commit_requests (notebook_id, request_id, request_hash, result)
    values (p_notebook_id, p_request_id, v_request_hash, v_result - 'suppressedIds');

  return v_result;
end;
$$;

revoke all on function public.commit_notebook(uuid, bigint, uuid, jsonb) from public, anon;
grant execute on function public.commit_notebook(uuid, bigint, uuid, jsonb) to authenticated;

-- ────────────────────────────────────────────────────────────
-- Deletion
-- ────────────────────────────────────────────────────────────

-- M4: the current brief goes on every delete, not only when it was written
-- from this notebook: a brief from another notebook can carry this one's
-- content through its `previous` input (brief.mjs). A new one is written at
-- the next close.
create or replace function public.delete_notebook(p_notebook_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return jsonb_build_object('deleted', false);
  end if;

  -- Lock the owner's notebook; someone else's (or a missing one) is a no-op,
  -- so a retry after success is safe and nothing reveals other users' ids.
  perform 1 from public.notebooks
    where id = p_notebook_id and user_id = v_uid
    for update;
  if not found then
    return jsonb_build_object('deleted', false);
  end if;

  delete from public.session_briefs where user_id = v_uid;

  delete from public.retrieve_rate_limits
    where scope = 'notebook:' || p_notebook_id::text;

  -- Cascades to everything keyed by notebook_id.
  delete from public.notebooks
    where id = p_notebook_id and user_id = v_uid;

  return jsonb_build_object('deleted', true);
end;
$$;

revoke all on function public.delete_notebook(uuid) from public, anon;
grant execute on function public.delete_notebook(uuid) to authenticated;

-- M6: 20261104000700's body, plus the retrieval counter, which has no foreign
-- key to cascade from. An off-the-record session can touch it.
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

-- Grants on everything new or replaced above that isn't granted already.
revoke all on function public._slugify(text) from public, anon, authenticated;
revoke all on function public._no_word_gaps(text) from public, anon, authenticated;
revoke all on function public._redact_inside_word(text, bytea, text[]) from public, anon, authenticated;
revoke all on function public._redact_text(text, bytea, text[], boolean) from public, anon, authenticated;
revoke all on function public.redact_forgotten(uuid, text) from public, anon, authenticated;
revoke all on function public._jsonb_redact_forgotten(uuid, jsonb) from public, anon, authenticated;
revoke all on function public._forget_slugs(uuid, text) from public, anon, authenticated;
revoke all on function public._forget_mentions(jsonb, bytea, text[], boolean, text) from public, anon, authenticated;
revoke all on function public._forget_counts(uuid, text, text[]) from public, anon, authenticated;
revoke all on function public._forgotten_ids(uuid, text[]) from public, anon, authenticated;
revoke all on function public.redact_forgotten_text(text) from public, anon;
grant execute on function public.redact_forgotten_text(text) to authenticated;
revoke all on function public.forget_entity_preview(text) from public, anon;
grant execute on function public.forget_entity_preview(text) to authenticated;
revoke all on function public.forget_entity(text) from public, anon;
grant execute on function public.forget_entity(text) to authenticated;

drop function public._jsonb_redact(jsonb, text, text, text);
drop function public._jsonb_mentions(jsonb, text, text);
drop function public._name_pattern(text[]);
