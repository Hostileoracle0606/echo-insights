-- Session briefs (LM-37): the opening of the next session.
--
-- One row per user: a short brief generated from the notebook the user just
-- left (focus, a thread to pick up, and one spoken opening line) plus the
-- opening line's audio (PCM16 mono). It is written by the brief runtime route
-- when a just_talk notebook closes, read by the app when a session starts,
-- and marked played once it has been heard, so it never plays twice.
--
-- The runtime calls save_session_brief with the user's own token, never a
-- service key, so ownership is checked here exactly as for save_session_card.

-- ────────────────────────────────────────────────────────────
-- 1. session_briefs
--
-- Readable by the owner; written only by the functions below.
-- ────────────────────────────────────────────────────────────
create table public.session_briefs (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  source_notebook_id uuid references public.notebooks(id) on delete set null,
  source_revision    bigint not null,
  -- {focus: text[], openingThread: text, openingLine: text}
  brief              jsonb not null,
  audio              bytea not null,
  sample_rate        int not null,
  created_at         timestamptz not null default now(),
  played_at          timestamptz
);

alter table public.session_briefs enable row level security;

create policy "owner select" on public.session_briefs
  for select using (auth.uid() = user_id);

revoke all on table public.session_briefs from anon;
revoke insert, update, delete, truncate on table public.session_briefs from authenticated;

-- ────────────────────────────────────────────────────────────
-- 2. save_session_brief
--
-- SECURITY DEFINER, so it bypasses RLS: every statement filters by
-- v_uid = auth.uid(), never a user-id parameter. The notebook row is locked
-- first (commit_notebook's lock order).
--
-- A save replaces the user's row, restarts created_at and clears played_at,
-- unless the row is already for this notebook at the same or a newer revision
-- (a retried close): then nothing is written and the caller gets 'unchanged'.
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

-- ────────────────────────────────────────────────────────────
-- 3. get_session_brief
--
-- SECURITY INVOKER: RLS limits every read to the caller's own rows.
-- 'returning' is true for an account that has used the app before: any
-- notebook with entities, any turn the user spoke, or any session card.
-- createdAt keeps full microsecond precision so the app can send it back to
-- mark_session_brief_played unchanged.
-- ────────────────────────────────────────────────────────────
create or replace function public.get_session_brief()
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'returning',
      exists (select 1 from public.notebooks n
              where n.user_id = auth.uid() and n.entity_count > 0)
      or exists (select 1 from public.conversation_turns t
                 where t.user_id = auth.uid() and t.speaker = 'user')
      or exists (select 1 from public.session_cards c
                 where c.user_id = auth.uid()),
    'brief',
      (select jsonb_build_object(
          'focus', sb.brief->'focus',
          'openingThread', sb.brief->'openingThread',
          'openingLine', sb.brief->'openingLine',
          'sourceNotebookId', sb.source_notebook_id,
          'createdAt', sb.created_at,
          'playedAt', sb.played_at,
          'sampleRate', sb.sample_rate,
          'audioBase64', replace(encode(sb.audio, 'base64'), E'\n', ''))
       from public.session_briefs sb
       where sb.user_id = auth.uid()));
$$;

revoke all on function public.get_session_brief() from public, anon;
grant execute on function public.get_session_brief() to authenticated;

-- ────────────────────────────────────────────────────────────
-- 4. mark_session_brief_played
--
-- Matches created_at exactly, so a brief saved since the app fetched the one
-- it played is never marked by mistake. Idempotent: an already-played brief
-- keeps its first played_at.
-- ────────────────────────────────────────────────────────────
create or replace function public.mark_session_brief_played(p_created_at timestamptz)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.session_briefs
    set played_at = now()
    where user_id = auth.uid()
      and created_at = p_created_at
      and played_at is null;
$$;

revoke all on function public.mark_session_brief_played(timestamptz) from public, anon;
grant execute on function public.mark_session_brief_played(timestamptz) to authenticated;
