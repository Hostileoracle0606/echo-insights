-- Phase 1 reconciliation (R15): what only breaks once the tickets combine.
--
-- Migrations apply in timestamp order, and create or replace keeps only the
-- last body. LM-49's 20261104000300_forget_regeneration.sql was written from
-- the pre-LM-46 definitions, so it silently dropped LM-46's input caps
-- (20261104000000_rpc_input_caps.sql) from two functions. Redefined here with
-- both behaviours; signatures, grants, SECURITY DEFINER and search_path are
-- unchanged.
--
--   save_session_card    LM-46 caps + LM-49 redaction
--   save_session_brief   LM-46 caps + LM-49 "a brief naming a forgotten person
--                        is not saved"
--   delete_empty_notebook  LM-50's emptiness check + LM-51's marker: a notebook
--                        whose transcript was auto-forgotten only looks empty
--
-- Every other function defined by more than one migration keeps its last
-- definition: commit_notebook (LM-46 only, and it calls LM-49's
-- _commit_apply_turn after the caps), _commit_apply_turn, remove_entity,
-- get_notebook_snapshot and forget_entity (LM-49 only, within that ticket),
-- forget_old_transcripts (LM-51 only, within that ticket).

-- ────────────────────────────────────────────────────────────
-- save_session_card: 20261104000300's body with 20261104000000's caps.
--
-- The caps run first, so an oversized input never reaches the tokenizer. The
-- title and summary are redacted before they are cut to length, not after:
-- cutting first could leave half a name that no longer matches.
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
  v_title text;
  v_summary text;
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

  -- LM-49 (R10): a forgotten name never lands in a stored card, however the
  -- card was written. Every string value, and the title and summary that
  -- are copied onto the notebook, goes through redact_forgotten.
  p_card := public._jsonb_redact_forgotten(v_uid, p_card);
  -- 60 / 280 = the title and summary limits in session-card-v1.
  v_title := left(public.redact_forgotten(v_uid, btrim(coalesce(p_title, ''), E' \t\r\n')), 60);
  v_summary := left(public.redact_forgotten(v_uid, btrim(coalesce(p_summary, ''), E' \t\r\n')), 280);

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
-- save_session_brief: 20261104000000's body with 20261104000300's check.
--
-- All input checks still run before the notebook is locked or the audio
-- decoded. The forgotten-name check reads the normalized brief, the only
-- fields that are stored and spoken, all of them capped by then; an extra key
-- in p_brief is never stored, and its length is not capped.
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

  -- LM-49 (R10): the audio already speaks whatever the text says, so a brief
  -- that names someone the user forgot is not saved at all. The previous
  -- brief stays, and 'unchanged' tells the runtime not to retry.
  if public._json_mentions_forgotten(v_uid, v_brief) then
    return jsonb_build_object('status', 'unchanged');
  end if;

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

-- ────────────────────────────────────────────────────────────
-- delete_empty_notebook: 20261104000500's body plus LM-51's marker.
--
-- Auto-forget can leave a notebook with no rows at all (turns swept, revision
-- still 0). That notebook held a real conversation, so an off-the-record visit
-- must not delete it on leaving.
-- ────────────────────────────────────────────────────────────
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

  delete from public.notebooks where id = p_notebook_id and user_id = auth.uid();
  return jsonb_build_object('deleted', true);
end;
$$;

revoke all on function public.delete_empty_notebook(uuid) from public, anon;
grant execute on function public.delete_empty_notebook(uuid) to authenticated;
