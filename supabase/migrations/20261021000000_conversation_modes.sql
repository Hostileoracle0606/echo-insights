-- Conversation modes on notebooks (LM-01).
--
-- A notebook now records which kind of conversation it is. Every existing
-- and default-inserted notebook is just_talk; later tickets create the other
-- modes and are the first to read the column.
--
-- Naming: conversation_runtime_sessions.mode already means the *extraction*
-- mode (wiki / granular), so this is always conversation_mode, never mode.

-- ────────────────────────────────────────────────────────────
-- 1. notebooks.conversation_mode and mode_context
--
-- mode_context holds per-mode inputs, e.g. {"weekOf": "2026-10-23"} for a
-- debrief or {"scheduledSessionId": "…"} for prep. No schema yet: later
-- tickets define the keys per mode.
-- ────────────────────────────────────────────────────────────
alter table public.notebooks
  add column conversation_mode text not null default 'just_talk'
    check (conversation_mode in ('weekly_debrief','session_prep','what_landed','first_session','just_talk')),
  add column mode_context jsonb not null default '{}'::jsonb;

-- "This user's last debrief" and the like.
create index notebooks_user_mode_started_idx
  on public.notebooks (user_id, conversation_mode, started_at desc);

-- ────────────────────────────────────────────────────────────
-- 2. get_entity_mentions: add conversationMode to each mention
--
-- Same signature and body as 20261020000000_user_memory.sql; the only change
-- is the 'conversationMode' key. create or replace keeps the existing grants
-- (execute for authenticated, revoked from public and anon), so they aren't
-- repeated here.
-- ────────────────────────────────────────────────────────────
create or replace function public.get_entity_mentions(
  p_entity_id text,
  p_limit int default 20,
  p_before timestamptz default null
) returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  with hits as (
    select je.id, je.notebook_id, je.text, je.created_at
    from public.journal_entries je
    where je.user_id = auth.uid()
      and je.entity_ids @> array[p_entity_id]
  ),
  page as (
    select h.*
    from hits h
    where p_before is null or h.created_at < p_before
    order by h.created_at desc, h.id desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  )
  select jsonb_build_object(
    'total', (select count(*) from hits),
    'mentions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entryId', p.id, 'notebookId', p.notebook_id,
        'notebookTitle', nb.title, 'notebookStartedAt', nb.started_at,
        'conversationMode', nb.conversation_mode,
        'createdAt', p.created_at, 'excerpt', left(p.text, 280),
        'turnId', t.turn_id, 'spokenAt', t.spoken_at
      ) order by p.created_at desc, p.id desc)
      from page p
      join public.notebooks nb on nb.id = p.notebook_id
      left join lateral (
        select ct.turn_id, ct.spoken_at
        from public.conversation_turns ct
        where ct.notebook_id = p.notebook_id
          and ct.speaker = 'user'
          and ct.text = p.text
          and ct.spoken_at <= p.created_at
        order by ct.spoken_at desc
        limit 1
      ) t on true
    ), '[]'::jsonb)
  );
$$;
