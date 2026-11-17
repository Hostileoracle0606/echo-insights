-- LM-102: card and brief saves are keyed and safe to repeat; the phone can ask
-- a definite question before it spends a model call.
--
-- Keys: a card is (notebook, source revision); a brief is (user, notebook,
-- source revision). Each row stores payload_hash, the sha256 of the payload as
-- offered, never the payload again. A row saved before this migration has a
-- null hash and adopts the first payload that matches its key.
--
--   same key, same payload       -> as before (card: 'saved' with the stored
--                                   card; brief: 'unchanged')
--   same key, different payload  -> {status:'rejected', code:'keyReused'},
--                                   nothing written
--   stale / newer-revision rules -> unchanged
--
-- get_card_status / get_brief_status answer "is it there?" without returning
-- any card or brief text, so a caller can skip a model call it does not need.

alter table public.session_cards   add column payload_hash text;
alter table public.session_briefs  add column payload_hash text;

-- ────────────────────────────────────────────────────────────
-- save_session_card: 20261104000700's body plus the key check.
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
  v_hash text;
  v_existing record;
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
  -- LM-102: the key is (notebook, source revision); what is stored under it
  -- is a hash of the card as offered (before redaction), never the card again.
  v_hash := encode(sha256(convert_to(p_card::text, 'UTF8')), 'hex');

  select sc.source_revision, sc.payload_hash into v_existing
    from public.session_cards sc
    where sc.notebook_id = p_notebook_id and sc.user_id = v_uid;
  if found and v_existing.source_revision = p_source_revision then
    if v_existing.payload_hash is null then
      -- Saved before the ledger existed: adopt this payload as the key's hash.
      update public.session_cards
        set payload_hash = v_hash
        where notebook_id = p_notebook_id and user_id = v_uid;
    elsif v_existing.payload_hash <> v_hash then
      -- Same key, different payload: write nothing.
      return jsonb_build_object('status', 'rejected', 'code', 'keyReused');
    end if;
  end if;

  p_card := public._jsonb_redact_forgotten(v_uid, p_card);
  -- 60 / 280 = the title and summary limits in session-card-v1.
  v_title := left(public.redact_forgotten(v_uid, btrim(coalesce(p_title, ''), E' \t\r\n')), 60);
  v_summary := left(public.redact_forgotten(v_uid, btrim(coalesce(p_summary, ''), E' \t\r\n')), 280);

  insert into public.session_cards as sc
      (notebook_id, user_id, conversation_mode, source_revision, card, payload_hash)
    values
      (p_notebook_id, v_uid, v_notebook.conversation_mode, p_source_revision, p_card, v_hash)
  on conflict (notebook_id) do update
    set conversation_mode = excluded.conversation_mode,
        source_revision = excluded.source_revision,
        card = excluded.card,
        payload_hash = excluded.payload_hash,
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
-- save_session_brief: 20261107000000's body plus the key check.
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
  v_hash text;
  v_existing record;
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
  -- LM-56: no audio (null or '') is allowed. The app saves a brief without
  -- audio when its opening line, with the real names back, can't be spoken
  -- (too long for speech, or refused by the speak check). An empty clip is
  -- never playable (get_session_brief returns audioBase64 '' and the app
  -- plays the standard clip), but the brief's text carries forward.
  if coalesce(p_audio_base64, '') = '' then
    v_audio := ''::bytea;
  else
    begin
      v_audio := decode(p_audio_base64, 'base64');
    exception when others then
      raise exception 'audio is not valid base64' using errcode = '22023';
    end;
    if v_audio is null or octet_length(v_audio) = 0 then
      raise exception 'audio is empty' using errcode = '22023';
    end if;
    if octet_length(v_audio) > c_max_audio_bytes then
      raise exception 'audio is too large (max % bytes)', c_max_audio_bytes using errcode = '22023';
    end if;
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

  -- LM-102: the key is (user, notebook, source revision); what is stored under
  -- it is a hash of the normalised brief, never the brief again.
  v_hash := encode(sha256(convert_to(v_brief::text, 'UTF8')), 'hex');

  select sb.source_notebook_id, sb.source_revision, sb.payload_hash into v_existing
    from public.session_briefs sb
    where sb.user_id = v_uid;
  if found
     and v_existing.source_notebook_id is not distinct from p_notebook_id
     and v_existing.source_revision = p_source_revision then
    if v_existing.payload_hash is null then
      -- Saved before the ledger existed: adopt this payload as the key's hash.
      update public.session_briefs set payload_hash = v_hash where user_id = v_uid;
    elsif v_existing.payload_hash <> v_hash then
      return jsonb_build_object('status', 'rejected', 'code', 'keyReused');
    end if;
    return jsonb_build_object('status', 'unchanged');
  end if;

  insert into public.session_briefs as sb
      (user_id, source_notebook_id, source_revision, brief, audio, sample_rate,
       created_at, played_at, payload_hash)
    values
      (v_uid, p_notebook_id, p_source_revision, v_brief, v_audio, p_sample_rate,
       now(), null, v_hash)
  on conflict (user_id) do update
    set source_notebook_id = excluded.source_notebook_id,
        source_revision = excluded.source_revision,
        brief = excluded.brief,
        audio = excluded.audio,
        sample_rate = excluded.sample_rate,
        created_at = now(),
        played_at = null,
        payload_hash = excluded.payload_hash
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
-- get_card_status / get_brief_status
--
-- {status, cardRevision, currentRevision}:
--   notFound  the notebook is not the caller's (or does not exist)
--   stale     p_revision is not the notebook's current revision
--   present   a card (brief) exists for exactly p_revision
--   absent    otherwise
-- The brief read also names its revision as briefRevision. Owner-scoped,
-- read-only, never returns text.
-- ────────────────────────────────────────────────────────────
create or replace function public.get_card_status(
  p_notebook_id uuid,
  p_revision bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_current bigint;
  v_card bigint;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'notFound', 'cardRevision', null, 'currentRevision', null);
  end if;
  select n.revision into v_current
    from public.notebooks n
    where n.id = p_notebook_id and n.user_id = v_uid;
  if not found then
    return jsonb_build_object('status', 'notFound', 'cardRevision', null, 'currentRevision', null);
  end if;
  select sc.source_revision into v_card
    from public.session_cards sc
    where sc.notebook_id = p_notebook_id and sc.user_id = v_uid;
  return jsonb_build_object(
    'status', case
      when p_revision is distinct from v_current then 'stale'
      when v_card is not distinct from p_revision then 'present'
      else 'absent' end,
    'cardRevision', v_card,
    'currentRevision', v_current);
end;
$$;

revoke all on function public.get_card_status(uuid, bigint) from public, anon;
grant execute on function public.get_card_status(uuid, bigint) to authenticated;

create or replace function public.get_brief_status(
  p_notebook_id uuid,
  p_revision bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_current bigint;
  v_brief bigint;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'notFound', 'cardRevision', null,
      'briefRevision', null, 'currentRevision', null);
  end if;
  select n.revision into v_current
    from public.notebooks n
    where n.id = p_notebook_id and n.user_id = v_uid;
  if not found then
    return jsonb_build_object('status', 'notFound', 'cardRevision', null,
      'briefRevision', null, 'currentRevision', null);
  end if;
  -- One brief per user: it counts only when it is from this notebook.
  select sb.source_revision into v_brief
    from public.session_briefs sb
    where sb.user_id = v_uid and sb.source_notebook_id = p_notebook_id;
  return jsonb_build_object(
    'status', case
      when p_revision is distinct from v_current then 'stale'
      when v_brief is not distinct from p_revision then 'present'
      else 'absent' end,
    'cardRevision', v_brief,
    'briefRevision', v_brief,
    'currentRevision', v_current);
end;
$$;

revoke all on function public.get_brief_status(uuid, bigint) from public, anon;
grant execute on function public.get_brief_status(uuid, bigint) to authenticated;
