-- Forget can also erase the person's name from the user's own saved
-- transcripts, when they choose to. Off by default: by default (LM-63) the
-- transcript keeps the user's words in text and Lumen reads context_text.
-- Erasing edits the user's own words and can't be undone.
--
-- After 20261112100000 (LM-63) and 20261112200000, so their redefinitions of
-- forget_entity(text) and forget_entity_preview don't replace these.
--
--   forget_entity(p_entity_id, p_erase_transcripts) — new overload. Runs
--     forget_entity(p_entity_id) (LM-63's, which takes every notebook of the
--     caller's for update and recomputes context_text), then, when
--     p_erase_transcripts, rewrites the caller's conversation_turns.text and
--     journal_entries.text, across all notebooks, in keyset batches, still
--     under those locks. Only this person's names are matched, never a removed
--     word or another forgotten person. The rows' context_text triggers
--     (LM-63) recompute context_text from the new text, so the two stay
--     consistent (null when no forgotten name is left in it). Revisions are
--     not bumped again: the forget already moved every notebook whose entries
--     name the person, and cards that were current stay current (R6). The
--     result adds transcriptPassages, the number of rows rewritten.
--   forget_entity_preview — adds transcriptPassages, the rows that would change.
--   _transcript_redact — the matcher for one person's slugs (zero key, as
--     _forget_counts and LM-63's forget do), so preview and rewrite agree.
--
-- Only rows whose slugged text contains one of the person's slugs are run
-- through the matcher, as LM-63's forget does.

create function public._transcript_redact(p_text text, p_slugs text[])
returns text
language sql
stable
set search_path = public, extensions, pg_temp
as $$
  select public._redact_text(
    p_text, '\x00'::bytea,
    array(select encode(hmac(convert_to(s, 'UTF8'), '\x00'::bytea, 'sha256'), 'hex') from unnest(p_slugs) s),
    exists (select 1 from unnest(p_slugs) s where public._no_word_gaps(s)),
    (select coalesce(max(public._slug_words(s)), 1) from unnest(p_slugs) s));
$$;

-- Whether p_text could name the person: one of their slugs is in its slug.
create function public._transcript_may_name(p_text text, p_slugs text[])
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select exists (select 1 from unnest(p_slugs) s where position(s in public._slug_text(p_text)) > 0);
$$;

create function public._transcript_passages(p_uid uuid, p_slugs text[])
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (select count(*) from public.conversation_turns t
          where t.user_id = p_uid and public._transcript_may_name(t.text, p_slugs)
            and public._transcript_redact(t.text, p_slugs) <> t.text)::int
       + (select count(*) from public.journal_entries e
          where e.user_id = p_uid and public._transcript_may_name(e.text, p_slugs)
            and public._transcript_redact(e.text, p_slugs) <> e.text)::int;
$$;

create or replace function public.forget_entity_preview(p_entity_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_slugs text[];
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;
  v_slugs := public._forget_slugs(v_uid, p_entity_id);
  return public._forget_counts(v_uid, p_entity_id, v_slugs)
         || jsonb_build_object('transcriptPassages', public._transcript_passages(v_uid, v_slugs));
end;
$$;

create function public.forget_entity(p_entity_id text, p_erase_transcripts boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_slugs text[];
  v_counts jsonb;
  v_batch constant int := 500;
  v_rows int;
  v_total int := 0;
  v_last_nb uuid := '00000000-0000-0000-0000-000000000000';
  v_last_turn text := '';
  v_last_entry uuid := '00000000-0000-0000-0000-000000000000';
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;

  -- Before forget_entity deletes the entity and its name with it.
  v_slugs := public._forget_slugs(v_uid, p_entity_id);
  -- LM-63's forget: locks the caller's notebooks until this transaction ends.
  v_counts := public.forget_entity(p_entity_id);
  if not coalesce(p_erase_transcripts, false) then
    return v_counts;
  end if;

  -- Turns, a batch at a time in primary-key order. Only the caller's rows.
  -- Setting text fires the context_text trigger.
  loop
    with batch as (
      select t.notebook_id, t.turn_id from public.conversation_turns t
       where t.user_id = v_uid and (t.notebook_id, t.turn_id) > (v_last_nb, v_last_turn)
       order by t.notebook_id, t.turn_id
       limit v_batch
    ), changed as (
      update public.conversation_turns t
         set text = public._transcript_redact(t.text, v_slugs)
        from batch b
       where t.notebook_id = b.notebook_id and t.turn_id = b.turn_id
         and public._transcript_may_name(t.text, v_slugs)
         and public._transcript_redact(t.text, v_slugs) <> t.text
      returning 1
    )
    select (select count(*) from changed),
           (select notebook_id from batch order by notebook_id desc, turn_id desc limit 1),
           (select turn_id from batch order by notebook_id desc, turn_id desc limit 1)
      into v_rows, v_last_nb, v_last_turn;
    v_total := v_total + v_rows;
    exit when v_last_nb is null;
  end loop;

  loop
    with batch as (
      select e.id from public.journal_entries e
       where e.user_id = v_uid and e.id > v_last_entry
       order by e.id
       limit v_batch
    ), changed as (
      update public.journal_entries e
         set text = public._transcript_redact(e.text, v_slugs)
        from batch b
       where e.id = b.id
         and public._transcript_may_name(e.text, v_slugs)
         and public._transcript_redact(e.text, v_slugs) <> e.text
      returning 1
    )
    select (select count(*) from changed), (select max(id::text)::uuid from batch)
      into v_rows, v_last_entry;
    v_total := v_total + v_rows;
    exit when v_last_entry is null;
  end loop;

  return v_counts || jsonb_build_object('transcriptPassages', v_total);
end;
$$;

revoke all on function public._transcript_redact(text, text[]) from public, anon, authenticated;
revoke all on function public._transcript_may_name(text, text[]) from public, anon, authenticated;
revoke all on function public._transcript_passages(uuid, text[]) from public, anon, authenticated;
revoke all on function public.forget_entity_preview(text) from public, anon;
grant execute on function public.forget_entity_preview(text) to authenticated;
revoke all on function public.forget_entity(text, boolean) from public, anon;
grant execute on function public.forget_entity(text, boolean) to authenticated;
