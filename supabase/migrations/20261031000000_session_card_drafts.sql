-- save_session_card: drafts while the conversation is still going.
--
-- The app now asks for a draft card in the background as the conversation
-- goes on, so the closing card can show something recent the moment the
-- user leaves instead of waiting ~4 s for the model. A draft is generated
-- from the notebook at some revision and saved seconds later, when the
-- user may already have said more: p_draft => true keeps it (still never
-- replacing a newer card) instead of refusing it as stale. Final cards
-- (p_draft false, the default) keep the exact-revision rule.
--
-- Same body as 20261024000000 apart from the revision check. Dropped and
-- recreated rather than overloaded: with the new parameter defaulted, a
-- second overload would make the existing five-argument calls ambiguous.

drop function public.save_session_card(uuid, bigint, jsonb, text, text);

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
