-- LM-102 follow-up: a draft never claims the card key.
--
-- Drafts are saved while the conversation goes on (p_draft). The final card
-- for the same revision must still replace the draft, so the ledger records
-- whether the stored row is a draft:
--   final at R over a draft at R        replaces it and takes the key hash
--   final at R, same hash as a final    returns the stored card
--   final at R, other hash than a final keyReused, nothing written
--   draft at R over a final at >= R     returns the stored final
--   draft at R over a draft at R        keeps the first, as before
-- A draft's payload_hash stays null. get_card_status gains `draft` (additive)
-- so a caller can tell "a draft is there" from "the final is there".

alter table public.session_cards add column is_draft boolean not null default false;

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

  select sc.source_revision, sc.payload_hash, sc.is_draft into v_existing
    from public.session_cards sc
    where sc.notebook_id = p_notebook_id and sc.user_id = v_uid;
  -- A draft never claims the key and is never refused for it: a final at the
  -- same revision replaces a stored draft; a draft never replaces a final at
  -- the same or a newer revision (the upsert below leaves it, and the stored
  -- card comes back).
  if not p_draft and found and v_existing.source_revision = p_source_revision
     and not v_existing.is_draft then
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
      (notebook_id, user_id, conversation_mode, source_revision, card, payload_hash, is_draft)
    values
      (p_notebook_id, v_uid, v_notebook.conversation_mode, p_source_revision, p_card,
       case when p_draft then null else v_hash end, p_draft)
  on conflict (notebook_id) do update
    set conversation_mode = excluded.conversation_mode,
        source_revision = excluded.source_revision,
        card = excluded.card,
        payload_hash = excluded.payload_hash,
        is_draft = excluded.is_draft,
        updated_at = now()
    where sc.user_id = v_uid
      and (sc.source_revision < excluded.source_revision
           or (sc.is_draft and not excluded.is_draft
               and sc.source_revision = excluded.source_revision))
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
  v_draft boolean;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'notFound', 'cardRevision', null, 'currentRevision', null, 'draft', false);
  end if;
  select n.revision into v_current
    from public.notebooks n
    where n.id = p_notebook_id and n.user_id = v_uid;
  if not found then
    return jsonb_build_object('status', 'notFound', 'cardRevision', null, 'currentRevision', null, 'draft', false);
  end if;
  select sc.source_revision, sc.is_draft into v_card, v_draft
    from public.session_cards sc
    where sc.notebook_id = p_notebook_id and sc.user_id = v_uid;
  return jsonb_build_object(
    'status', case
      when p_revision is distinct from v_current then 'stale'
      when v_card is not distinct from p_revision then 'present'
      else 'absent' end,
    'cardRevision', v_card,
    'currentRevision', v_current,
    'draft', coalesce(v_draft, false));
end;
$$;

revoke all on function public.get_card_status(uuid, bigint) from public, anon;
grant execute on function public.get_card_status(uuid, bigint) to authenticated;
