-- LM-49 fix round (R10): a forgotten name must not come back through
-- regeneration.
--
--   _slugify(text)                 — the extractor's slug rule in SQL
--   redact_forgotten(uid, text)    — internal: replaces any 1-3 word run whose
--                                    slug hashes to one of the user's
--                                    suppressions with "someone"
--   redact_forgotten_text(text)    — client/Lambda wrapper using auth.uid()
--   save_session_card (replaced)   — redacts every string, title and summary
--   save_session_brief (replaced)  — does not save a brief that names one
--   forget_entity (replaced)       — redacted cards are marked current
--   get_notebook_snapshot          — the suppressedEntityIds field is removed:
--    (replaced)                      a device cannot hash, and the snapshot
--                                    never contains a forgotten entity anyway
--
-- Slug rule = slugify() in src/lib/journal-store.ts and lib/logic (lowercase,
-- NFKD, drop combining marks, non-alphanumerics to "-", trim, 60 chars).

create or replace function public._slugify(p_text text)
returns text
language sql
immutable
as $$
  select left(btrim(regexp_replace(
    regexp_replace(normalize(lower(coalesce(p_text, '')), NFKD), '[̀-ͯ]', '', 'g'),
    '[^a-z0-9]+', '-', 'g'), '-'), 60);
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
  v_toks text[];
  v_word boolean[];
  v_n int;
  v_i int := 1;
  v_len int;
  v_k int;
  v_slug text;
  v_hit boolean;
begin
  if p_text is null or p_text = '' then
    return p_text;
  end if;
  select k.key into v_key from public.suppression_keys k where k.user_id = p_uid;
  if v_key is null then
    return p_text;
  end if;
  select coalesce(array_agg(s.entity_hash), '{}') into v_hashes
    from public.entity_suppressions s where s.user_id = p_uid;
  if cardinality(v_hashes) = 0 then
    return p_text;
  end if;

  -- Alternating words and the gaps between them, in order.
  select array_agg(coalesce(t.r[1], t.r[2]) order by t.ord),
         array_agg(t.r[1] is not null order by t.ord)
    into v_toks, v_word
    from regexp_matches(p_text, '([[:alnum:]]+)|([^[:alnum:]]+)', 'g') with ordinality as t(r, ord);
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
        if encode(hmac(convert_to(v_slug, 'UTF8'), v_key, 'sha256'), 'hex') = any(v_hashes) then
          v_toks[v_i] := 'someone';
          for g in v_i + 1 .. v_k loop
            v_toks[g] := '';
          end loop;
          v_i := v_k + 1;
          v_hit := true;
          exit;
        end if;
      end loop;
    end if;
    if not v_hit then
      v_i := v_i + 1;
    end if;
  end loop;

  return array_to_string(v_toks, '');
end;
$$;

-- The client/Lambda entry point: the caller's own suppressions only.
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
  return public.redact_forgotten(auth.uid(), p_text);
end;
$$;

-- p_json with every string value run through redact_forgotten. Keys and
-- structure are untouched; uuids and dates are left alone. Objects that name
-- a suppressed entity (an "entityId") are dropped from their array.
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
        select jsonb_object_agg(k, public._jsonb_redact_forgotten(p_uid, v))
        from jsonb_each(p_json) as t(k, v)
      ), '{}'::jsonb);
    else
      return p_json;
  end case;
end;
$$;

-- True when redacting any string value of p_json would change it.
create or replace function public._json_mentions_forgotten(p_uid uuid, p_json jsonb)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from jsonb_path_query(p_json, 'strict $.**') v
    where jsonb_typeof(v) = 'string'
      and public.redact_forgotten(p_uid, v #>> '{}') is distinct from (v #>> '{}')
  );
$$;

revoke all on function public._slugify(text) from public, anon, authenticated;
revoke all on function public.redact_forgotten(uuid, text) from public, anon, authenticated;
revoke all on function public._jsonb_redact_forgotten(uuid, jsonb) from public, anon, authenticated;
revoke all on function public._json_mentions_forgotten(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.redact_forgotten_text(text) from public, anon;
grant execute on function public.redact_forgotten_text(text) to authenticated;

-- ────────────────────────────────────────────────────────────
-- save_session_card — replaced; 20261031000000's body plus the redaction
-- ────────────────────────────────────────────────────────────
create or replace function public.save_session_card(
  p_notebook_id uuid,
  p_source_revision bigint,
  p_card jsonb,
  p_title text,
  p_summary text,
  p_draft boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_notebook record;
  -- 60 / 280 = the title and summary limits in session-card-v1.
  v_title text := left(btrim(coalesce(p_title, ''), E' \t\r\n'), 60);
  v_summary text := left(btrim(coalesce(p_summary, ''), E' \t\r\n'), 280);
  v_saved jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  select * into v_notebook
    from public.notebooks
    where id = p_notebook_id and user_id = v_uid
    for update;

  if not found then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  if p_draft then
    -- A draft is written while the conversation goes on: by the time it is
    -- saved the notebook may have moved past the revision it was written
    -- from. Keep it (the upsert below still never replaces a newer card);
    -- a draft can never be ahead of the notebook.
    if p_source_revision is null or p_source_revision > v_notebook.revision then
      raise exception 'draft revision % is ahead of the notebook (%)',
        p_source_revision, v_notebook.revision using errcode = '22023';
    end if;
  elsif p_source_revision is distinct from v_notebook.revision then
    return jsonb_build_object('status', 'stale', 'currentRevision', v_notebook.revision);
  end if;

  -- The card must describe this notebook at this revision, so a stored card
  -- can always be trusted to say what it is for.
  if jsonb_typeof(p_card) is distinct from 'object'
     or p_card->'version' is distinct from '1'::jsonb
     or p_card->>'notebookId' is distinct from p_notebook_id::text
     or p_card->'sourceRevision' is distinct from to_jsonb(p_source_revision)
     or p_card->>'conversationMode' is distinct from v_notebook.conversation_mode then
    raise exception 'card does not match the notebook' using errcode = '22023';
  end if;

  -- LM-49 (R10): a forgotten name never lands in a stored card, however the
  -- card was written. Every string value, and the title and summary that
  -- are copied onto the notebook, goes through redact_forgotten.
  p_card := public._jsonb_redact_forgotten(v_uid, p_card);
  v_title := left(public.redact_forgotten(v_uid, v_title), 60);
  v_summary := left(public.redact_forgotten(v_uid, v_summary), 280);

  insert into public.session_cards as sc
      (notebook_id, user_id, conversation_mode, source_revision, card)
    values
      (p_notebook_id, v_uid, v_notebook.conversation_mode, p_source_revision, p_card)
  on conflict (notebook_id) do update
    set conversation_mode = excluded.conversation_mode,
        source_revision = excluded.source_revision,
        card = excluded.card,
        updated_at = now()
    where sc.user_id = v_uid
      and sc.source_revision < excluded.source_revision
  returning sc.card into v_saved;

  if v_saved is null then
    -- A card for this revision was already saved: hand that one back.
    select sc.card into v_saved
      from public.session_cards sc
      where sc.notebook_id = p_notebook_id and sc.user_id = v_uid;
    return jsonb_build_object('status', 'saved', 'card', v_saved);
  end if;

  update public.notebooks
    set title = case
          when title_source <> 'user' and v_title <> '' then v_title
          else title
        end,
        title_source = case
          when title_source <> 'user' and v_title <> '' then 'ai'
          else title_source
        end,
        summary = case when v_summary <> '' then v_summary else summary end,
        updated_at = now()
    where id = p_notebook_id and user_id = v_uid;

  return jsonb_build_object('status', 'saved', 'card', v_saved);
end;
$$;

revoke all on function public.save_session_card(uuid, bigint, jsonb, text, text, boolean) from public, anon;
grant execute on function public.save_session_card(uuid, bigint, jsonb, text, text, boolean) to authenticated;

-- save_session_brief — replaced; 20261029000000's body plus the check
create or replace function public.save_session_brief(
  p_notebook_id uuid,
  p_source_revision bigint,
  p_brief jsonb,
  p_audio_base64 text,
  p_sample_rate int
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_line text;
  v_brief jsonb;
  v_audio bytea;
  v_saved uuid;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  perform 1
    from public.notebooks
    where id = p_notebook_id and user_id = v_uid
    for update;

  if not found then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  if jsonb_typeof(p_brief) is distinct from 'object' then
    raise exception 'brief must be an object' using errcode = '22023';
  end if;

  v_line := btrim(coalesce(p_brief->>'openingLine', ''), E' \t\r\n');
  if v_line = '' or char_length(v_line) > 160 then
    raise exception 'openingLine must be 1 to 160 characters' using errcode = '22023';
  end if;

  -- LM-49 (R10): the audio already speaks whatever the text says, so a brief
  -- that names someone the user forgot is not saved at all. The previous
  -- brief stays, and 'unchanged' tells the runtime not to retry.
  if public._json_mentions_forgotten(v_uid, p_brief) then
    return jsonb_build_object('status', 'unchanged');
  end if;

  begin
    v_audio := decode(coalesce(p_audio_base64, ''), 'base64');
  exception when others then
    raise exception 'audio is not valid base64' using errcode = '22023';
  end;
  if v_audio is null or octet_length(v_audio) = 0 then
    raise exception 'audio is empty' using errcode = '22023';
  end if;

  if p_sample_rate is null or p_sample_rate <= 0 then
    raise exception 'sample rate must be positive' using errcode = '22023';
  end if;

  v_brief := jsonb_build_object(
    'focus', case when jsonb_typeof(p_brief->'focus') = 'array'
                  then p_brief->'focus' else '[]'::jsonb end,
    'openingThread', coalesce(p_brief->>'openingThread', ''),
    'openingLine', v_line);

  insert into public.session_briefs as sb
      (user_id, source_notebook_id, source_revision, brief, audio, sample_rate,
       created_at, played_at)
    values
      (v_uid, p_notebook_id, p_source_revision, v_brief, v_audio, p_sample_rate,
       now(), null)
  on conflict (user_id) do update
    set source_notebook_id = excluded.source_notebook_id,
        source_revision = excluded.source_revision,
        brief = excluded.brief,
        audio = excluded.audio,
        sample_rate = excluded.sample_rate,
        created_at = now(),
        played_at = null
    where sb.user_id = v_uid
      and (sb.source_notebook_id is distinct from excluded.source_notebook_id
           or sb.source_revision < excluded.source_revision)
  returning sb.user_id into v_saved;

  if v_saved is null then
    return jsonb_build_object('status', 'unchanged');
  end if;
  return jsonb_build_object('status', 'saved');
end;
$$;

revoke all on function public.save_session_brief(uuid, bigint, jsonb, text, int) from public, anon;
grant execute on function public.save_session_brief(uuid, bigint, jsonb, text, int) to authenticated;

-- forget_entity — replaced (redacted cards are marked current)
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
  -- The redacted card is marked as current for the notebook's new revision
  -- (forgetting bumped it), so it is not regenerated just for being stale.
  -- Only a card that was current before the bump is advanced; a genuinely
  -- stale one still regenerates.
  update public.session_cards c
    set card = case when c.source_revision = nb.revision - 1
                    then jsonb_set(
                           public._jsonb_redact(c.card, v_pat, p_entity_id, 'someone'),
                           '{sourceRevision}', to_jsonb(nb.revision))
                    else public._jsonb_redact(c.card, v_pat, p_entity_id, 'someone') end,
        source_revision = case when c.source_revision = nb.revision - 1
                               then nb.revision else c.source_revision end,
        updated_at = now()
    from public.notebooks nb
    where nb.id = c.notebook_id and c.user_id = v_uid
      and public._jsonb_mentions(c.card, v_pat, p_entity_id);

  if v_pat is not null then
    update public.notebooks
      set title = regexp_replace(title, v_pat, 'someone', 'gi'),
          summary = regexp_replace(summary, v_pat, 'someone', 'gi')
      where user_id = v_uid and (title ~* v_pat or summary ~* v_pat);
  end if;

  return v_counts;
end;
$$;

revoke all on function public.forget_entity(text) from public, anon;
grant execute on function public.forget_entity(text) to authenticated;

-- get_notebook_snapshot — replaced (no suppressedEntityIds)
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

