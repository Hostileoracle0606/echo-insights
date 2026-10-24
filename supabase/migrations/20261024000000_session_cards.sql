-- Session cards (LM-15): the result a conversation ends with.
--
-- One card per notebook, written by the close-session runtime route
-- (infra/lambda/close-session) when the user leaves a notebook. The card's
-- shape is contracts/session-card-v1.schema.json. A notebook can be resumed,
-- so the card records the notebooks.revision it was generated from; leaving
-- again at a newer revision regenerates it.
--
-- The runtime calls save_session_card with the user's own token, never a
-- service key, so ownership is checked here exactly as for commit_notebook.

-- ────────────────────────────────────────────────────────────
-- 1. session_cards
--
-- Readable by the owner; written only by save_session_card below.
-- ────────────────────────────────────────────────────────────
create table public.session_cards (
  notebook_id       uuid primary key references public.notebooks(id) on delete cascade,
  user_id           uuid not null references auth.users(id) on delete cascade,
  conversation_mode text not null,
  source_revision   bigint not null,
  card              jsonb not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

alter table public.session_cards enable row level security;

create policy "owner select" on public.session_cards
  for select using (auth.uid() = user_id);

revoke all on table public.session_cards from anon;
revoke insert, update, delete, truncate on table public.session_cards from authenticated;

-- ────────────────────────────────────────────────────────────
-- 2. save_session_card
--
-- SECURITY DEFINER, so it bypasses RLS: every statement filters by
-- v_uid = auth.uid(), never a user-id parameter.
--
-- Writes only when the notebook is still at p_source_revision. Otherwise the
-- conversation changed while the card was being generated, and the caller
-- gets {status: 'stale', currentRevision} with nothing written. The notebook
-- row is locked first (commit_notebook's lock order), so a commit racing
-- this call either lands before the check (stale) or waits until the card is
-- saved and then makes it out of date by bumping the revision.
--
-- An existing card is replaced only by one from a newer revision. Two
-- generations of the same revision (a rare duplicate close) keep the first,
-- and both callers get that stored card back, so a retried close returns the
-- same card. Saving never bumps notebooks.revision, or the card would be
-- stale the moment it landed.
--
-- The notebook's title becomes p_title (title_source 'ai') unless the user
-- named it ('user'); its summary becomes p_summary.
-- ────────────────────────────────────────────────────────────
create or replace function public.save_session_card(
  p_notebook_id uuid,
  p_source_revision bigint,
  p_card jsonb,
  p_title text,
  p_summary text
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

  if p_source_revision is distinct from v_notebook.revision then
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

revoke all on function public.save_session_card(uuid, bigint, jsonb, text, text) from public, anon;
grant execute on function public.save_session_card(uuid, bigint, jsonb, text, text) to authenticated;
