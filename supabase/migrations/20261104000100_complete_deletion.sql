-- Complete deletion (LM-48): the account, and a single session.
--
-- Account: every user-data table cascades from auth.users(id), directly or
-- through notebooks, so deleting the auth user removes it all; the one table
-- with no foreign key (retrieve_rate_limits) is purged by the
-- on_auth_user_deleted trigger (20260922000000). Nothing newer needs a change,
-- and no table writes to a storage bucket. supabase/tests/database/
-- deletion_guard_test.sql fails when a table is added without a deletion path.
--
-- Session: notebooks own their rows, so deleting the notebook removes its
-- turns, journal entries, card (and draft), commit requests, runtime session
-- and inbox, follow-ups, asked questions, and the entities, relations and
-- embeddings it contributed. The graph is per notebook (entities and
-- relations are keyed by (notebook_id, id)), so an entity that other
-- notebooks also mention stays through their own rows. Two things do not
-- follow the cascade and are handled here:
--   * session_briefs.source_notebook_id is ON DELETE SET NULL, which would
--     keep a brief written from the deleted conversation (spoken audio
--     included); the brief is deleted instead.
--   * retrieve_rate_limits has no foreign key; its 'notebook:<id>' counters
--     are deleted.
-- entity_suppressions are the user's own "forget this" choices, not session
-- content, so they stay.
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

  delete from public.session_briefs
    where user_id = v_uid and source_notebook_id = p_notebook_id;

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
