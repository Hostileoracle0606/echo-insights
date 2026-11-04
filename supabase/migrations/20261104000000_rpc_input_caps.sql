-- Size caps and type checks on the write RPCs (LM-46).
--
-- A signed-in caller can send these functions anything, so each one now
-- refuses an oversized or wrongly typed input up front with SQLSTATE 22023
-- (invalid_parameter_value). Messages name the field and the limit only,
-- never the value, so no journal content reaches an error message or a log.
--
-- Signatures and grants are unchanged (create or replace), so the app and the
-- Lambdas need no change. The caps sit well above what they send today:
--
--   save_session_brief  audio            2 MiB decoded. The opener is ~3-8 s of
--                                        24 kHz 16-bit mono PCM, 150-400 KB.
--                                        2.8 M base64 chars is checked first,
--                                        so an oversized string is never decoded.
--                       sample rate      1..192000 (the app sends 24000)
--                       focus            array, <= 10 strings, <= 500 chars each
--                                        (the brief prompt asks for 4 x 140)
--                       openingThread    string, <= 1000 chars (prompt: 200)
--                       openingLine      <= 160 chars (unchanged)
--                       source revision  null raises 22023 (was 23502)
--   save_session_card   card             object, <= 64 KiB as text (a card is a
--                                        few KB: 60 + 280 chars, 5 notes, 8
--                                        remember rows)
--                       title / summary  <= 1000 chars in (still cut to 60/280)
--                       source revision  null raises 22023 (was 'stale')
--   commit_notebook     change           object, <= 256 KiB as text (entry text
--                                        is <= 8000 chars, <= 50 entities and
--                                        50 relations)
--                       entity           name <= 200, description <= 2000
--                                        chars, <= 20 questions of <= 500 chars
--                       relation label   <= 200 chars
--                       followUp / askedQuestion  question and reason <= 1000

-- ────────────────────────────────────────────────────────────
-- 1. commit_notebook caps
--
-- Private helper (no grant), called from commit_notebook after the ownership
-- check. It raises 22023 on a violation; commit_notebook catches that and
-- returns {status: rejected, code: invalidChange} as data. The existing
-- invalidChange checks in _commit_apply_turn are untouched.
-- ────────────────────────────────────────────────────────────
create or replace function public._commit_check_caps(p_change jsonb)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  c_max_change_bytes constant int := 262144;
  c_max_name         constant int := 200;
  c_max_description  constant int := 2000;
  c_max_questions    constant int := 20;
  c_max_question     constant int := 500;
  c_max_label        constant int := 200;
  c_max_follow_up    constant int := 1000;
  v_part jsonb;
  v_field text;
begin
  if jsonb_typeof(p_change) is distinct from 'object' then
    raise exception 'change must be an object' using errcode = '22023';
  end if;
  if octet_length(p_change::text) > c_max_change_bytes then
    raise exception 'change is too large (max % bytes)', c_max_change_bytes using errcode = '22023';
  end if;

  -- The remaining shapes only matter to applyTurn.
  if p_change->>'kind' is distinct from 'applyTurn' then
    return;
  end if;

  foreach v_field in array array['entities', 'relations'] loop
    if p_change->v_field is not null and jsonb_typeof(p_change->v_field) not in ('array', 'null') then
      raise exception '% must be an array', v_field using errcode = '22023';
    end if;
  end loop;

  if jsonb_typeof(p_change->'entities') = 'array' then
    if exists (select 1 from jsonb_array_elements(p_change->'entities') e
               where jsonb_typeof(e) is distinct from 'object') then
      raise exception 'entities must be objects' using errcode = '22023';
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_change->'entities') e
      where char_length(coalesce(e->>'name', '')) > c_max_name
         or char_length(coalesce(e->>'description', '')) > c_max_description
         or (jsonb_typeof(e->'questions') not in ('array', 'null'))
         or (jsonb_typeof(e->'questions') = 'array'
             and (jsonb_array_length(e->'questions') > c_max_questions
                  or exists (select 1 from jsonb_array_elements(e->'questions') q
                             where jsonb_typeof(q) is distinct from 'string'
                                or char_length(q #>> '{}') > c_max_question)))
    ) then
      raise exception 'an entity exceeds its field limits' using errcode = '22023';
    end if;
  end if;

  if jsonb_typeof(p_change->'relations') = 'array' then
    if exists (select 1 from jsonb_array_elements(p_change->'relations') r
               where jsonb_typeof(r) is distinct from 'object') then
      raise exception 'relations must be objects' using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements(p_change->'relations') r
               where char_length(coalesce(r->>'label', '')) > c_max_label) then
      raise exception 'a relation label is too long' using errcode = '22023';
    end if;
  end if;

  foreach v_field in array array['followUp', 'askedQuestion'] loop
    v_part := p_change->v_field;
    if v_part is null or jsonb_typeof(v_part) = 'null' then
      continue;
    end if;
    if jsonb_typeof(v_part) <> 'object' then
      raise exception '% must be an object', v_field using errcode = '22023';
    end if;
    if char_length(coalesce(v_part->>'question', '')) > c_max_follow_up
       or char_length(coalesce(v_part->>'reason', '')) > c_max_follow_up then
      raise exception '% text is too long', v_field using errcode = '22023';
    end if;
  end loop;
end;
$$;

revoke all on function public._commit_check_caps(jsonb) from public, anon, authenticated;

-- commit_notebook: 20260821000000's definition verbatim except for the
-- _commit_check_caps call after the ownership check.
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
    values (p_notebook_id, p_request_id, v_request_hash, v_result);

  return v_result;
end;
$$;

revoke all on function public.commit_notebook(uuid, bigint, uuid, jsonb) from public, anon;
grant execute on function public.commit_notebook(uuid, bigint, uuid, jsonb) to authenticated;

-- ────────────────────────────────────────────────────────────
-- 2. save_session_card caps
--
-- 20261031000000's definition with: a null revision raising 22023 up front
-- (a final card used to come back 'stale'), a size cap on the card, and caps
-- on the title and summary inputs.
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
  c_max_card_bytes constant int := 65536;
  c_max_title_in   constant int := 1000;
  c_max_summary_in constant int := 1000;
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

  if p_source_revision is null then
    raise exception 'source revision is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_card) is distinct from 'object' then
    raise exception 'card must be an object' using errcode = '22023';
  end if;
  if octet_length(p_card::text) > c_max_card_bytes then
    raise exception 'card is too large (max % bytes)', c_max_card_bytes using errcode = '22023';
  end if;
  if char_length(coalesce(p_title, '')) > c_max_title_in
     or char_length(coalesce(p_summary, '')) > c_max_summary_in then
    raise exception 'title or summary is too long' using errcode = '22023';
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
    if p_source_revision > v_notebook.revision then
      raise exception 'draft revision % is ahead of the notebook (%)',
        p_source_revision, v_notebook.revision using errcode = '22023';
    end if;
  elsif p_source_revision is distinct from v_notebook.revision then
    return jsonb_build_object('status', 'stale', 'currentRevision', v_notebook.revision);
  end if;

  -- The card must describe this notebook at this revision, so a stored card
  -- can always be trusted to say what it is for.
  if p_card->'version' is distinct from '1'::jsonb
     or p_card->>'notebookId' is distinct from p_notebook_id::text
     or p_card->'sourceRevision' is distinct from to_jsonb(p_source_revision)
     or p_card->>'conversationMode' is distinct from v_notebook.conversation_mode then
    raise exception 'card does not match the notebook' using errcode = '22023';
  end if;

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

-- ────────────────────────────────────────────────────────────
-- 3. save_session_brief caps
--
-- 20261029000000's definition with the caps listed at the top. All input
-- checks run before the notebook is locked or the audio decoded.
-- ────────────────────────────────────────────────────────────
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
  c_max_audio_bytes  constant int := 2097152;  -- 2 MiB decoded
  c_max_audio_chars  constant int := 2796204;  -- base64 length of 2 MiB (4/3 rounded up)
  c_max_sample_rate  constant int := 192000;
  c_max_focus_items  constant int := 10;
  c_max_focus_chars  constant int := 500;
  c_max_thread_chars constant int := 1000;
  c_max_line_chars   constant int := 160;
  v_uid uuid := auth.uid();
  v_line text;
  v_thread text;
  v_brief jsonb;
  v_audio bytea;
  v_saved uuid;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  if p_source_revision is null then
    raise exception 'source revision is required' using errcode = '22023';
  end if;

  if jsonb_typeof(p_brief) is distinct from 'object' then
    raise exception 'brief must be an object' using errcode = '22023';
  end if;

  v_line := btrim(coalesce(p_brief->>'openingLine', ''), E' \t\r\n');
  if jsonb_typeof(p_brief->'openingLine') is distinct from 'string'
     or v_line = '' or char_length(v_line) > c_max_line_chars then
    raise exception 'openingLine must be 1 to % characters', c_max_line_chars using errcode = '22023';
  end if;

  if p_brief->'openingThread' is null or jsonb_typeof(p_brief->'openingThread') = 'null' then
    v_thread := '';
  elsif jsonb_typeof(p_brief->'openingThread') <> 'string' then
    raise exception 'openingThread must be a string' using errcode = '22023';
  else
    v_thread := p_brief->>'openingThread';
    if char_length(v_thread) > c_max_thread_chars then
      raise exception 'openingThread must be at most % characters', c_max_thread_chars using errcode = '22023';
    end if;
  end if;

  if p_brief->'focus' is not null and jsonb_typeof(p_brief->'focus') <> 'null' then
    if jsonb_typeof(p_brief->'focus') <> 'array' then
      raise exception 'focus must be an array' using errcode = '22023';
    end if;
    if jsonb_array_length(p_brief->'focus') > c_max_focus_items then
      raise exception 'focus must have at most % items', c_max_focus_items using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements(p_brief->'focus') f
               where jsonb_typeof(f) is distinct from 'string'
                  or char_length(f #>> '{}') > c_max_focus_chars) then
      raise exception 'focus items must be strings of at most % characters', c_max_focus_chars
        using errcode = '22023';
    end if;
  end if;

  if p_sample_rate is null or p_sample_rate <= 0 or p_sample_rate > c_max_sample_rate then
    raise exception 'sample rate must be between 1 and %', c_max_sample_rate using errcode = '22023';
  end if;

  if char_length(coalesce(p_audio_base64, '')) > c_max_audio_chars then
    raise exception 'audio is too large (max % bytes)', c_max_audio_bytes using errcode = '22023';
  end if;
  begin
    v_audio := decode(coalesce(p_audio_base64, ''), 'base64');
  exception when others then
    raise exception 'audio is not valid base64' using errcode = '22023';
  end;
  if v_audio is null or octet_length(v_audio) = 0 then
    raise exception 'audio is empty' using errcode = '22023';
  end if;
  if octet_length(v_audio) > c_max_audio_bytes then
    raise exception 'audio is too large (max % bytes)', c_max_audio_bytes using errcode = '22023';
  end if;

  perform 1
    from public.notebooks
    where id = p_notebook_id and user_id = v_uid
    for update;

  if not found then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  v_brief := jsonb_build_object(
    'focus', case when jsonb_typeof(p_brief->'focus') = 'array'
                  then p_brief->'focus' else '[]'::jsonb end,
    'openingThread', v_thread,
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
