-- Forget can also erase the person's name from the user's own saved
-- transcripts, when they choose to. Off by default: by default (LM-63) the
-- transcript keeps the user's words in text and Lumen reads context_text.
-- Erasing edits the user's own words (theirs and Lumen's turns) and can't be
-- undone.
--
-- After 20261112100000 (LM-63) and 20261112200000, so their redefinitions of
-- forget_entity(text) and forget_entity_preview don't replace these.
--
-- R34. Only a name of two or more words can be erased. A one-word name
-- ("Will", "Mark") is also an ordinary word, and the matcher would rewrite
-- "Will you come?" or "Free Will" for good. The erase matches the person's
-- saved surfaces (their id and the name they were saved under) of two or
-- more words only; when there is none, it is not offered and the server
-- refuses it (22023). As for every forget, only the name as saved is matched:
-- erasing "Maya Chen" leaves "Maya" alone.
--
-- R35. The forget never waits for, or fails because of, the erase.
-- forget_entity(p_entity_id, true) runs LM-63's forget and queues a job
-- (forget_erase_jobs); forget_erase_step rewrites a bounded number of rows
-- per call, notebook by notebook along their indexes, and says how many rows
-- are left to check. The app runs the steps with progress and resumes a
-- pending job (forget_erase_pending) on its next launch. Each rewritten row's
-- context_text is recomputed by LM-63's trigger, so text and context_text
-- stay consistent. Revisions are not bumped: the forget already moved every
-- notebook whose entries name the person, and current cards stay current (R6).
--
-- The job holds no readable name: only the keyed hashes of the names to
-- erase (_suppression_hash, the user's own key, as entity_suppressions holds
-- them), how many words the longest has, and the time of the forget. Rows
-- saved after that time are not erased. The row is deleted when the job
-- finishes. Clients can't read the table; the account's deletion cascades to
-- it. It is not part of the export. The preview and sample match with the
-- zero key: they store nothing.

-- ────────────────────────────────────────────────────────────
-- Matching
-- ────────────────────────────────────────────────────────────

-- The person's surfaces that may be erased: two or more words.
create function public._erase_slugs(p_slugs text[])
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(s order by s), '{}') from unnest(p_slugs) s where public._slug_words(s) >= 2;
$$;

-- p_text with this person's slugs replaced, with the zero key, for the
-- preview and the sample, which store nothing. The erase itself matches the
-- same names through the job's keyed hashes and the user's key.
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
-- About 20 µs a row; the matcher runs only where this holds.
create function public._transcript_may_name(p_text text, p_slugs text[])
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select exists (select 1 from unnest(p_slugs) s where position(s in public._slug_text(p_text)) > 0);
$$;

-- Rows of the caller's that the erase would change, counted up to p_cap.
-- Reached through the user's notebooks, so the turns' primary key is used.
create function public._transcript_passages(p_uid uuid, p_slugs text[], p_cap int)
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(*)::int from (
    select 1 from (
      select t.text from public.notebooks nb
        join public.conversation_turns t on t.notebook_id = nb.id
       where nb.user_id = p_uid
      union all
      select e.text from public.journal_entries e where e.user_id = p_uid
    ) r
    where cardinality(p_slugs) > 0
      and public._transcript_may_name(r.text, p_slugs)
      and public._transcript_redact(r.text, p_slugs) <> r.text
    limit p_cap
  ) x;
$$;

-- ────────────────────────────────────────────────────────────
-- Preview and sample
-- ────────────────────────────────────────────────────────────

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
  v_erase text[];
  v_cap constant int := 500;
  v_count int;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;
  v_slugs := public._forget_slugs(v_uid, p_entity_id);
  v_erase := public._erase_slugs(v_slugs);
  v_count := public._transcript_passages(v_uid, v_erase, v_cap);
  return public._forget_counts(v_uid, p_entity_id, v_slugs)
         || jsonb_build_object('transcriptPassages', v_count,
                               'transcriptPassagesCapped', v_count >= v_cap,
                               'eraseAvailable', cardinality(v_erase) > 0);
end;
$$;

-- A few passages the erase would change, before and after (the user's own
-- words, shown in the confirmation). Each is cut to 400 characters before it
-- is matched, so before and after line up.
create function public.forget_erase_sample(p_entity_id text, p_limit int default 3)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_erase text[];
  v_names text[];
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;
  v_erase := public._erase_slugs(public._forget_slugs(v_uid, p_entity_id));
  if cardinality(v_erase) = 0 then
    return jsonb_build_object('available', false, 'passages', '[]'::jsonb);
  end if;
  -- The names as saved, to tell a match written that way from one that isn't.
  v_names := array(select distinct e.name from public.entities e
                    where e.user_id = v_uid and e.id = p_entity_id and coalesce(e.name, '') <> '');
  -- Riskier passages first: where the name isn't written as it was saved
  -- ("maya chen", "MAYA Chen"), the match is the least obvious. Ranked on
  -- the cheap prefilter, then the matcher runs on the first 50 candidates
  -- only, not on every row that may name them.
  return jsonb_build_object('available', true, 'passages', coalesce((
    select jsonb_agg(jsonb_build_object('before', m.b, 'after', m.a) order by m.risky desc, m.ord)
    from (
      select r.b, r.a, r.risky, r.ord from (
        select c.b, c.risky, c.ord, public._transcript_redact(c.b, v_erase) as a
        from (
          select x.b, x.risky, row_number() over (order by x.risky desc) as ord
          from (
            select y.b, not exists (select 1 from unnest(v_names) n where strpos(y.b, n) > 0) as risky
            from (
              select left(t.text, 400) as b
                from public.notebooks nb join public.conversation_turns t on t.notebook_id = nb.id
               where nb.user_id = v_uid and public._transcript_may_name(t.text, v_erase)
              union all
              select left(e.text, 400) from public.journal_entries e
               where e.user_id = v_uid and public._transcript_may_name(e.text, v_erase)
            ) y
          ) x
          order by x.risky desc
          limit 50
        ) c
      ) r
      where r.a <> r.b
      order by r.risky desc, r.ord
      limit least(greatest(coalesce(p_limit, 3), 1), 5)
    ) m
  ), '[]'::jsonb));
end;
$$;

-- ────────────────────────────────────────────────────────────
-- Jobs
-- ────────────────────────────────────────────────────────────

create table public.forget_erase_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- _suppression_hash of the entity id: one job per person, no name.
  entity_hash text not null,
  -- The names to erase, as keyed hashes (_suppression_hash): never a
  -- readable name, never an unkeyed hash.
  hashes text[] not null,
  -- The matcher's settings for those names.
  max_words int not null,
  match_inside boolean not null default false,
  -- When the person was forgotten: rows saved later are not erased.
  cutoff timestamptz not null default now(),
  -- Cursor: the notebook being read (null: not started), its turns then its
  -- entries, each in its index order.
  notebook_id uuid,
  phase text not null default 'turns' check (phase in ('turns', 'entries')),
  last_turn text not null default '',
  last_entry_at timestamptz,
  last_entry_id uuid,
  rewritten int not null default 0,
  created_at timestamptz not null default now(),
  unique (user_id, entity_hash)
);
alter table public.forget_erase_jobs enable row level security;
revoke all on table public.forget_erase_jobs from public, anon, authenticated;
comment on table public.forget_erase_jobs is
  'Pending "erase their name from my transcripts" runs. Holds the names until done; read only through forget_erase_*.';

create function public.forget_entity(p_entity_id text, p_erase_transcripts boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_erase text[];
  v_counts jsonb;
  v_job uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_entity_id, '') = '' then
    raise exception 'entity id is required' using errcode = '22023';
  end if;
  if not coalesce(p_erase_transcripts, false) then
    return public.forget_entity(p_entity_id);
  end if;

  -- Before the forget deletes the entity and its name with it.
  v_erase := public._erase_slugs(public._forget_slugs(v_uid, p_entity_id));
  if cardinality(v_erase) = 0 then
    raise exception 'a one-word name cannot be erased from transcripts' using errcode = '22023';
  end if;

  v_counts := public.forget_entity(p_entity_id);
  insert into public.forget_erase_jobs (user_id, entity_hash, hashes, max_words, match_inside)
    values (v_uid, public._suppression_hash(v_uid, p_entity_id),
            array(select public._suppression_hash(v_uid, s) from unnest(v_erase) s),
            (select max(public._slug_words(s)) from unnest(v_erase) s),
            exists (select 1 from unnest(v_erase) s where public._no_word_gaps(s)))
    on conflict (user_id, entity_hash) do update
      set hashes = excluded.hashes, max_words = excluded.max_words,
          match_inside = excluded.match_inside, cutoff = excluded.cutoff,
          rewritten = 0, notebook_id = null, phase = 'turns', last_turn = '',
          last_entry_at = null, last_entry_id = null
    returning id into v_job;
  return v_counts || jsonb_build_object('eraseJobId', v_job);
end;
$$;

-- The caller's pending erases (no names): for the app to resume them.
create function public.forget_erase_pending()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', j.id, 'rewritten', j.rewritten) order by j.created_at)
    from public.forget_erase_jobs j where j.user_id = auth.uid()
  ), '[]'::jsonb);
end;
$$;

-- Rows of the caller's not yet checked by job p_job.
create function public._erase_remaining(p_job public.forget_erase_jobs)
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  -- Only rows saved by the forget count: later ones aren't erased.
  select case when p_job.notebook_id is null then
    (select count(*) from public.notebooks nb join public.conversation_turns t on t.notebook_id = nb.id
      where nb.user_id = p_job.user_id and t.created_at <= p_job.cutoff)
    + (select count(*) from public.journal_entries e
        where e.user_id = p_job.user_id and e.created_at <= p_job.cutoff)
  else
    (select count(*) from public.notebooks nb join public.conversation_turns t on t.notebook_id = nb.id
      where nb.user_id = p_job.user_id and nb.id > p_job.notebook_id and t.created_at <= p_job.cutoff)
    + (select count(*) from public.notebooks nb join public.journal_entries e on e.notebook_id = nb.id
        where nb.user_id = p_job.user_id and nb.id > p_job.notebook_id and e.created_at <= p_job.cutoff)
    + case when p_job.phase = 'turns' then
        (select count(*) from public.conversation_turns t
          where t.notebook_id = p_job.notebook_id and t.turn_id > p_job.last_turn
            and t.created_at <= p_job.cutoff)
        + (select count(*) from public.journal_entries e
            where e.notebook_id = p_job.notebook_id and e.created_at <= p_job.cutoff)
      else
        (select count(*) from public.journal_entries e
          where e.notebook_id = p_job.notebook_id and e.created_at <= p_job.cutoff
            and (e.created_at, e.id) > (coalesce(p_job.last_entry_at, '-infinity'),
                                        coalesce(p_job.last_entry_id, '00000000-0000-0000-0000-000000000000')))
      end
  end::int;
$$;

-- Checks up to p_batch more rows of job p_job, rewriting those that name the
-- person. Returns {rewritten (this call), total, remaining (rows left to
-- check), finished}. A job that is done, or not the caller's, is finished.
-- Calls for one job run one at a time (the job row is locked).
create function public.forget_erase_step(p_job_id uuid, p_batch int default 300)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_job public.forget_erase_jobs;
  v_budget int := least(greatest(coalesce(p_batch, 300), 1), 2000);
  v_seen int;
  v_done int;
  v_rewritten int := 0;
  v_last_turn text;
  v_last_at timestamptz;
  v_last_id uuid;
  v_key bytea;
  v_remaining int;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select * into v_job from public.forget_erase_jobs
   where id = p_job_id and user_id = v_uid for update;
  if not found then
    return jsonb_build_object('rewritten', 0, 'total', 0, 'remaining', 0, 'finished', true);
  end if;
  -- The user's key, once: the job's hashes were made with it.
  select k.key into v_key from public.suppression_keys k where k.user_id = v_uid;

  while v_budget > 0 loop
    if v_job.notebook_id is null then
      v_job.notebook_id := (select id from public.notebooks where user_id = v_uid order by id limit 1);
      exit when v_job.notebook_id is null;
    end if;

    if v_job.phase = 'turns' then
      -- The matcher runs once per candidate row.
      with batch as (
        select t.turn_id, t.text, t.context_text, t.created_at from public.conversation_turns t
         where t.notebook_id = v_job.notebook_id and t.turn_id > v_job.last_turn
         order by t.turn_id limit v_budget
      ), cand as materialized (
        -- A row naming her has context_text (LM-63); only those, saved by
        -- the forget, are matched.
        select b.turn_id, b.text,
               public._redact_text(b.text, v_key, v_job.hashes, v_job.match_inside, v_job.max_words) as out
          from batch b where b.context_text is not null and b.created_at <= v_job.cutoff
      ), changed as (
        update public.conversation_turns t set text = c.out
          from cand c
         where t.notebook_id = v_job.notebook_id and t.turn_id = c.turn_id
           and t.user_id = v_uid and c.out <> c.text
        returning 1
      )
      select (select count(*) from batch), (select count(*) from changed),
             (select max(turn_id) from batch)
        into v_seen, v_done, v_last_turn;
      v_rewritten := v_rewritten + v_done;
      if v_seen < v_budget then
        v_job.phase := 'entries';
        v_job.last_entry_at := null;
        v_job.last_entry_id := null;
      else
        v_job.last_turn := v_last_turn;
      end if;
      v_budget := v_budget - v_seen;
    else
      with batch as (
        select e.id, e.created_at, e.text, e.context_text from public.journal_entries e
         where e.notebook_id = v_job.notebook_id
           and (e.created_at, e.id) > (coalesce(v_job.last_entry_at, '-infinity'),
                                       coalesce(v_job.last_entry_id, '00000000-0000-0000-0000-000000000000'))
         order by e.created_at, e.id limit v_budget
      ), cand as materialized (
        select b.id, b.text,
               public._redact_text(b.text, v_key, v_job.hashes, v_job.match_inside, v_job.max_words) as out
          from batch b where b.context_text is not null and b.created_at <= v_job.cutoff
      ), changed as (
        update public.journal_entries e set text = c.out
          from cand c
         where e.id = c.id and e.user_id = v_uid and c.out <> c.text
        returning 1
      ), last as (
        select created_at, id from batch order by created_at desc, id desc limit 1
      )
      select (select count(*) from batch), (select count(*) from changed),
             (select created_at from last), (select id from last)
        into v_seen, v_done, v_last_at, v_last_id;
      v_rewritten := v_rewritten + v_done;
      if v_seen < v_budget then
        -- This notebook is done: the next one.
        v_job.notebook_id := (select id from public.notebooks
                               where user_id = v_uid and id > v_job.notebook_id order by id limit 1);
        v_job.phase := 'turns';
        v_job.last_turn := '';
        v_job.last_entry_at := null;
        v_job.last_entry_id := null;
        if v_job.notebook_id is null then
          v_budget := 0;
          exit;
        end if;
      else
        v_job.last_entry_at := v_last_at;
        v_job.last_entry_id := v_last_id;
      end if;
      v_budget := v_budget - v_seen;
    end if;
  end loop;

  v_job.rewritten := v_job.rewritten + v_rewritten;
  if v_job.notebook_id is not null then
    v_remaining := public._erase_remaining(v_job);
  end if;
  -- Nothing left to check is finished, never "0 remaining, not finished".
  if v_job.notebook_id is null or v_remaining = 0 then
    -- Done: the names go with the row.
    delete from public.forget_erase_jobs where id = v_job.id;
    return jsonb_build_object('rewritten', v_rewritten, 'total', v_job.rewritten,
                              'remaining', 0, 'finished', true);
  end if;
  update public.forget_erase_jobs
     set notebook_id = v_job.notebook_id, phase = v_job.phase, last_turn = v_job.last_turn,
         last_entry_at = v_job.last_entry_at, last_entry_id = v_job.last_entry_id,
         rewritten = v_job.rewritten
   where id = v_job.id;
  return jsonb_build_object('rewritten', v_rewritten, 'total', v_job.rewritten,
                            'remaining', v_remaining, 'finished', false);
end;
$$;

revoke all on function public._erase_slugs(text[]) from public, anon, authenticated;
revoke all on function public._transcript_redact(text, text[]) from public, anon, authenticated;
revoke all on function public._transcript_may_name(text, text[]) from public, anon, authenticated;
revoke all on function public._transcript_passages(uuid, text[], int) from public, anon, authenticated;
revoke all on function public._erase_remaining(public.forget_erase_jobs) from public, anon, authenticated;
revoke all on function public.forget_entity_preview(text) from public, anon;
grant execute on function public.forget_entity_preview(text) to authenticated;
revoke all on function public.forget_erase_sample(text, int) from public, anon;
grant execute on function public.forget_erase_sample(text, int) to authenticated;
revoke all on function public.forget_entity(text, boolean) from public, anon;
grant execute on function public.forget_entity(text, boolean) to authenticated;
revoke all on function public.forget_erase_pending() from public, anon;
grant execute on function public.forget_erase_pending() to authenticated;
revoke all on function public.forget_erase_step(uuid, int) from public, anon;
grant execute on function public.forget_erase_step(uuid, int) to authenticated;
