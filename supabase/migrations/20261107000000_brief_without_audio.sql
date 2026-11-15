-- LM-56: save_session_brief may save a brief without audio.
--
-- From LM-56 the app saves the brief itself (request v2, contracts/
-- session-brief-v1.md). When the opening line, with the real names put back,
-- can't be spoken (longer than the speak step accepts, or the speak check
-- refuses it), the app saves the brief's text with no audio instead of losing
-- it: the next conversation opens with the standard clip, and the focus and
-- thread still carry forward. Everything else is 20261104000700's body:
-- the caps, the owner check, the revision rule, the forgotten-name check.
-- Signature, grants, SECURITY DEFINER and search_path are unchanged.

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
