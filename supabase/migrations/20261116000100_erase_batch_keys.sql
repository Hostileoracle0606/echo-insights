-- LM-102: erase batches keyed by (job, batch number).
--
-- forget_erase_batch(job, batch_no, batch) runs one step of the transcript
-- erase once per key. The same batch twice returns the stored result and
-- rewrites nothing; the same key with another batch size is refused
-- (keyReused); a batch that is not the next one is refused (outOfOrder, with
-- nextBatch). The ledger holds counts and a hash of the batch size: never
-- text or names. When the last batch finishes the job, the job row goes and
-- the ledger with it (on delete cascade); a repeat then finds no job and
-- comes back finished.
--
-- The step logic moves, unchanged, into _forget_erase_run(uid, job, batch);
-- forget_erase_step (older clients) and forget_erase_batch both call it.
-- forget_erase_pending() gains nextBatch (additive).

alter table public.forget_erase_jobs add column batches_done int not null default 0;

create table public.forget_erase_batches (
  job_id uuid not null references public.forget_erase_jobs (id) on delete cascade,
  batch_no int not null,
  -- sha256 of the batch size: never text or names.
  request_hash text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key (job_id, batch_no)
);
alter table public.forget_erase_batches enable row level security;
revoke all on table public.forget_erase_batches from public, anon, authenticated;
comment on table public.forget_erase_batches is
  'LM-102 ledger of erase batches run per job. Counts and a hash only; read through forget_erase_batch.';

-- The existing step, for a given user (the callers have checked auth.uid()).
create function public._forget_erase_run(p_uid uuid, p_job_id uuid, p_batch int default 300)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := p_uid;
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

-- The step for the older client: the same function, as before.
create or replace function public.forget_erase_step(p_job_id uuid, p_batch int default 300)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  return public._forget_erase_run(auth.uid(), p_job_id, p_batch);
end;
$$;

create function public.forget_erase_batch(p_job_id uuid, p_batch_no int, p_batch int default 300)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_job public.forget_erase_jobs;
  v_hash text;
  v_seen public.forget_erase_batches;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select * into v_job from public.forget_erase_jobs
   where id = p_job_id and user_id = v_uid for update;
  if not found then
    return jsonb_build_object('rewritten', 0, 'total', 0, 'remaining', 0, 'finished', true);
  end if;
  v_hash := encode(digest(convert_to('batch=' || coalesce(p_batch, 300)::text, 'UTF8'), 'sha256'), 'hex');

  select * into v_seen from public.forget_erase_batches
   where job_id = p_job_id and batch_no = p_batch_no;
  if found then
    if v_seen.request_hash <> v_hash then
      return jsonb_build_object('status', 'rejected', 'code', 'keyReused');
    end if;
    return v_seen.result;
  end if;
  if p_batch_no is distinct from v_job.batches_done + 1 then
    return jsonb_build_object('status', 'rejected', 'code', 'outOfOrder',
                              'nextBatch', v_job.batches_done + 1);
  end if;

  v_result := public._forget_erase_run(v_uid, p_job_id, p_batch)
              || jsonb_build_object('batchNo', p_batch_no);
  -- A finished run deleted the job (and so its ledger): nothing to record.
  if not (v_result ->> 'finished')::boolean then
    insert into public.forget_erase_batches (job_id, batch_no, request_hash, result)
      values (p_job_id, p_batch_no, v_hash, v_result);
    update public.forget_erase_jobs set batches_done = p_batch_no where id = p_job_id;
  end if;
  return v_result;
end;
$$;

create or replace function public.forget_erase_pending()
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
    select jsonb_agg(jsonb_build_object('id', j.id, 'rewritten', j.rewritten,
                                        'nextBatch', j.batches_done + 1) order by j.created_at)
    from public.forget_erase_jobs j where j.user_id = auth.uid()
  ), '[]'::jsonb);
end;
$$;

-- Forgetting the same person again restarts the job (new cutoff): its batch
-- numbers restart with it.
create function public._forget_erase_restart()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.batches_done := 0;
  delete from public.forget_erase_batches where job_id = new.id;
  return new;
end;
$$;
create trigger forget_erase_jobs_restart
  before update of cutoff on public.forget_erase_jobs
  for each row when (new.cutoff is distinct from old.cutoff)
  execute function public._forget_erase_restart();

revoke all on function public._forget_erase_restart() from public, anon, authenticated;
revoke all on function public._forget_erase_run(uuid, uuid, int) from public, anon, authenticated;
revoke all on function public.forget_erase_batch(uuid, int, int) from public, anon;
grant execute on function public.forget_erase_batch(uuid, int, int) to authenticated;
revoke all on function public.forget_erase_step(uuid, int) from public, anon;
grant execute on function public.forget_erase_step(uuid, int) to authenticated;
revoke all on function public.forget_erase_pending() from public, anon;
grant execute on function public.forget_erase_pending() to authenticated;
