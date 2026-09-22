-- Notebook Commit module — see docs/superpowers/specs/2026-08-21-notebook-commit-design.md
--
-- Replaces the client-driven delete-then-insert "snapshot save" (previously
-- src/lib/journal-store.ts saveState / lib/services/supabase_service.dart
-- saveState) with one authenticated, atomic, idempotent, optimistic-
-- concurrency-checked RPC. Web and iOS become adapters over this one
-- interface; PostgreSQL owns ownership, write order, UUID generation,
-- atomicity, and retry safety.
--
-- Two entry points, both SECURITY DEFINER (ownership is checked inside, not
-- delegated to RLS, so the revokes below can safely remove direct
-- authenticated access to the child tables without breaking either client):
--   commit_notebook(...)        — the only sanctioned write path
--   get_notebook_snapshot(...)  — the paired consistent read (one JSON object,
--                                  domain-shaped, includes the revision the
--                                  next commit_notebook call must supply)

-- ────────────────────────────────────────────────────────────
-- 1. notebooks.revision — optimistic-concurrency counter
-- ────────────────────────────────────────────────────────────
alter table public.notebooks
  add column if not exists revision bigint not null default 0;

-- ────────────────────────────────────────────────────────────
-- 2. notebook_commit_requests — idempotency ledger
--
-- Only COMMITTED outcomes are recorded: a conflict/rejected response never
-- mutated anything, so replaying the validation is harmless and cheap. A
-- stored row means "this exact (notebook, requestId) already committed
-- successfully — hand back the same result, don't re-apply."
-- ────────────────────────────────────────────────────────────
create table public.notebook_commit_requests (
  notebook_id  uuid not null references public.notebooks(id) on delete cascade,
  request_id   uuid not null,
  request_hash text not null,
  result       jsonb not null,
  created_at   timestamptz not null default now(),
  primary key (notebook_id, request_id)
);

-- Operational state, not user data: no client reads this directly (belt and
-- suspenders — the revoke matches the pattern already used for
-- retrieve_rate_limits / entity_embeddings).
alter table public.notebook_commit_requests enable row level security;
revoke all on table public.notebook_commit_requests from anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 3. commit_notebook — the only sanctioned write path
--
-- SECURITY DEFINER (runs as owner, bypassing RLS) so callers cannot mutate
-- child rows directly once the grants below are revoked. Fixed search_path
-- is mandatory for DEFINER safety. auth.uid() reads the request JWT claim and
-- works under DEFINER, same as bump_retrieve_rate.
--
-- Algorithm (see spec §"Transaction algorithm"):
--   1. reject unauthenticated callers
--   2. lock the owned notebook row (FOR UPDATE) — serializes concurrent
--      commits to the SAME notebook so the revision check + write is atomic
--      against races; "where user_id = v_uid" means a non-owner's call finds
--      no row, same response as a bad id, no ownership info leaked
--   3. idempotency: same requestId + same payload hash -> replay stored
--      result without re-applying; same requestId + different payload ->
--      requestIdReused
--   4. optimistic concurrency: expectedRevision must match the locked row's
--      revision, else conflict (no write)
--   5. validate the change (see per-kind blocks below)
--   6. apply it inside one exception-catching block — plpgsql creates an
--      implicit savepoint at "begin"; any raised exception inside rolls back
--      everything written so far in that block before the handler runs, so a
--      failure never leaves a partial write. Nothing here can leak past this
--      function: a single RPC call is one PostgREST transaction, so even an
--      *uncaught* error would abort the whole call — this handler exists so
--      expected failures come back as CommitOutcome data, not a thrown error.
--   7. bump revision + entity_count + updated_at
--   8. record the idempotency row
--   9. return the committed outcome
create or replace function public.commit_notebook(
  p_notebook_id uuid,
  p_expected_revision bigint,
  p_request_id uuid,
  p_change jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_notebook record;
  v_request_hash text;
  v_existing record;
  v_kind text;
  v_result jsonb;
  v_new_revision bigint;
  v_entity_count integer;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  -- Lock first: every other check below reads a value that could otherwise
  -- change out from under a concurrent commit to the same notebook.
  select * into v_notebook
    from public.notebooks
    where id = p_notebook_id and user_id = v_uid
    for update;

  if not found then
    return jsonb_build_object('status', 'rejected', 'code', 'notFound');
  end if;

  v_request_hash := md5(
    jsonb_build_object('change', p_change, 'expectedRevision', p_expected_revision)::text
  );

  select * into v_existing
    from public.notebook_commit_requests
    where notebook_id = p_notebook_id and request_id = p_request_id;

  if found then
    if v_existing.request_hash = v_request_hash then
      return v_existing.result; -- exact retry: hand back the prior outcome verbatim
    else
      return jsonb_build_object('status', 'rejected', 'code', 'requestIdReused');
    end if;
  end if;

  if p_expected_revision is distinct from v_notebook.revision then
    return jsonb_build_object('status', 'conflict', 'currentRevision', v_notebook.revision);
  end if;

  v_kind := p_change->>'kind';

  begin
    if v_kind = 'applyTurn' then
      v_result := public._commit_apply_turn(p_notebook_id, v_uid, p_change);
    elsif v_kind = 'answerFollowUp' then
      v_result := public._commit_answer_follow_up(p_notebook_id, p_change);
    elsif v_kind = 'clearNotebook' then
      v_result := public._commit_clear_notebook(p_notebook_id);
    else
      raise exception 'invalidChange: unknown kind %', coalesce(v_kind, '<null>');
    end if;
  exception
    when others then
      if sqlerrm like 'invalidChange:%' then
        return jsonb_build_object('status', 'rejected', 'code', 'invalidChange');
      end if;
      return jsonb_build_object('status', 'rejected', 'code', 'commitFailed');
  end;

  select count(*) into v_entity_count from public.entities where notebook_id = p_notebook_id;

  update public.notebooks
    set revision = revision + 1,
        updated_at = now(),
        entity_count = v_entity_count
    where id = p_notebook_id
    returning revision into v_new_revision;

  v_result := v_result
    || jsonb_build_object('status', 'committed', 'requestId', p_request_id, 'revision', v_new_revision);

  insert into public.notebook_commit_requests (notebook_id, request_id, request_hash, result)
    values (p_notebook_id, p_request_id, v_request_hash, v_result);

  return v_result;
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 3a. applyTurn — validate, then upsert entry/entities/relations/
--     followUp/askedQuestion. A private helper (not exposed as an RPC: no
--     grant below) so commit_notebook's exception block can catch its
--     raises cleanly. Runs under the caller's SECURITY DEFINER context.
-- ────────────────────────────────────────────────────────────
create or replace function public._commit_apply_turn(
  p_notebook_id uuid,
  p_uid uuid,
  p_change jsonb
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_entry jsonb := p_change->'entry';
  v_entry_text text := v_entry->>'text';
  v_entities jsonb := coalesce(p_change->'entities', '[]'::jsonb);
  v_relations jsonb := coalesce(p_change->'relations', '[]'::jsonb);
  v_follow_up jsonb := p_change->'followUp';
  v_asked jsonb := p_change->'askedQuestion';
  v_incoming_entity_ids text[];
  v_incoming_relation_ids text[];
  v_entry_entity_ids text[];
  v_entry_relation_ids text[];
  v_bad text;
  v_entry_id uuid;
  v_follow_up_id uuid;
begin
  if v_entry_text is null or length(trim(v_entry_text)) = 0 then
    raise exception 'invalidChange: entry.text is required';
  end if;
  if length(v_entry_text) > 8000 then
    raise exception 'invalidChange: entry.text too long';
  end if;
  if jsonb_array_length(v_entities) > 50 or jsonb_array_length(v_relations) > 50 then
    raise exception 'invalidChange: too many entities/relations in one commit';
  end if;

  select coalesce(array_agg(value->>'id'), '{}') into v_incoming_entity_ids
    from jsonb_array_elements(v_entities);
  select coalesce(array_agg(value->>'id'), '{}') into v_incoming_relation_ids
    from jsonb_array_elements(v_relations);

  -- Entity type must be one of the fixed set the clients render.
  select value->>'type' into v_bad
    from jsonb_array_elements(v_entities)
    where coalesce(value->>'id', '') = '' or coalesce(value->>'name', '') = ''
       or (value->>'type') not in
          ('person', 'place', 'organization', 'project', 'event', 'activity', 'concept', 'emotion', 'other')
    limit 1;
  if v_bad is not null then
    raise exception 'invalidChange: bad entity %', v_bad;
  end if;

  -- Relation endpoints must resolve — either an existing active-or-superseded
  -- entity row, or an entity arriving in this same commit (new entity + new
  -- relation created together in one turn).
  select value->>'source' into v_bad
    from jsonb_array_elements(v_relations) as r
    where coalesce(value->>'id', '') = '' or coalesce(value->>'label', '') = ''
       or (
         not exists (
           select 1 from public.entities e
           where e.notebook_id = p_notebook_id and e.id = r.value->>'source'
         )
         and not (v_incoming_entity_ids @> array[r.value->>'source'])
       )
       or (
         not exists (
           select 1 from public.entities e
           where e.notebook_id = p_notebook_id and e.id = r.value->>'target'
         )
         and not (v_incoming_entity_ids @> array[r.value->>'target'])
       )
    limit 1;
  if v_bad is not null then
    raise exception 'invalidChange: relation endpoint % not found', v_bad;
  end if;

  -- Entry provenance ids must reference something real (pre-existing or
  -- arriving in this commit) — never a dangling reference.
  select coalesce(array_agg(x), '{}') into v_entry_entity_ids
    from jsonb_array_elements_text(coalesce(v_entry->'entityIds', '[]'::jsonb)) as x;
  select coalesce(array_agg(x), '{}') into v_entry_relation_ids
    from jsonb_array_elements_text(coalesce(v_entry->'relationIds', '[]'::jsonb)) as x;

  select x into v_bad from unnest(v_entry_entity_ids) as x
    where not (v_incoming_entity_ids @> array[x])
      and not exists (
        select 1 from public.entities e where e.notebook_id = p_notebook_id and e.id = x
      )
    limit 1;
  if v_bad is not null then
    raise exception 'invalidChange: entry references unknown entity %', v_bad;
  end if;

  select x into v_bad from unnest(v_entry_relation_ids) as x
    where not (v_incoming_relation_ids @> array[x])
      and not exists (
        select 1 from public.relations rel where rel.notebook_id = p_notebook_id and rel.id = x
      )
    limit 1;
  if v_bad is not null then
    raise exception 'invalidChange: entry references unknown relation %', v_bad;
  end if;

  if v_follow_up is not null and coalesce(v_follow_up->>'question', '') = '' then
    raise exception 'invalidChange: followUp.question is required';
  end if;
  if v_asked is not null and coalesce(v_asked->>'question', '') = '' then
    raise exception 'invalidChange: askedQuestion.question is required';
  end if;

  -- ── apply ──────────────────────────────────────────────────
  insert into public.journal_entries
    (id, user_id, notebook_id, text, created_at, entity_ids, relation_ids)
  values
    (gen_random_uuid(), p_uid, p_notebook_id, v_entry_text, now(), v_entry_entity_ids, v_entry_relation_ids)
  returning id into v_entry_id;

  if jsonb_array_length(v_entities) > 0 then
    insert into public.entities
      (id, user_id, notebook_id, name, type, description, metadata, mentions, first_seen, last_seen, questions)
    select
      value->>'id', p_uid, p_notebook_id, value->>'name', value->>'type', value->>'description',
      coalesce(value->'metadata', '{}'::jsonb),
      (value->>'mentions')::integer,
      coalesce((value->>'firstSeen')::timestamptz, now()),
      coalesce((value->>'lastSeen')::timestamptz, now()),
      case when value->'questions' is null then null
           else array(select jsonb_array_elements_text(value->'questions')) end
    from jsonb_array_elements(v_entities)
    on conflict (notebook_id, id) do update set
      name = excluded.name,
      type = excluded.type,
      description = excluded.description,
      metadata = excluded.metadata,
      mentions = excluded.mentions,
      last_seen = excluded.last_seen,
      questions = excluded.questions;
  end if;

  if jsonb_array_length(v_relations) > 0 then
    insert into public.relations
      (id, user_id, notebook_id, source_id, target_id, label, metadata, created_at, superseded_at)
    select
      value->>'id', p_uid, p_notebook_id, value->>'source', value->>'target', value->>'label',
      coalesce(value->'metadata', '{}'::jsonb),
      coalesce((value->>'createdAt')::timestamptz, now()),
      (value->>'supersededAt')::timestamptz
    from jsonb_array_elements(v_relations)
    -- source_id/target_id/label never change for an existing row: the
    -- relation's id IS "<source>__<label>__<target>". Only metadata and the
    -- supersede state are mutable via re-assertion / contradiction.
    on conflict (notebook_id, id) do update set
      metadata = excluded.metadata,
      superseded_at = excluded.superseded_at;
  end if;

  if v_follow_up is not null then
    insert into public.follow_ups
      (id, user_id, notebook_id, question, reason, target_entity_ids, answered, created_at)
    values (
      gen_random_uuid(), p_uid, p_notebook_id, v_follow_up->>'question',
      coalesce(v_follow_up->>'reason', ''),
      coalesce(
        array(select jsonb_array_elements_text(coalesce(v_follow_up->'targetEntityIds', '[]'::jsonb))),
        '{}'
      ),
      false, now()
    )
    returning id into v_follow_up_id;
  end if;

  if v_asked is not null then
    insert into public.asked_questions (user_id, notebook_id, question, target_entity_ids, asked_at)
    values (
      p_uid, p_notebook_id, v_asked->>'question',
      coalesce(
        array(select jsonb_array_elements_text(coalesce(v_asked->'targetEntityIds', '[]'::jsonb))),
        '{}'
      ),
      now()
    );
    -- Same cap the client used to enforce (ASKED_QUESTIONS_CAP = 30):
    -- server-owned now, so both clients read a consistently-trimmed log.
    delete from public.asked_questions
    where notebook_id = p_notebook_id
      and id not in (
        select id from public.asked_questions
        where notebook_id = p_notebook_id
        order by asked_at desc
        limit 30
      );
  end if;

  return jsonb_build_object('ids', jsonb_build_object('entryId', v_entry_id, 'followUpId', v_follow_up_id));
end;
$$;

create or replace function public._commit_answer_follow_up(
  p_notebook_id uuid,
  p_change jsonb
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_follow_up_id uuid := (p_change->>'followUpId')::uuid;
  v_rows integer;
begin
  if v_follow_up_id is null then
    raise exception 'invalidChange: followUpId is required';
  end if;

  update public.follow_ups
    set answered = true
    where id = v_follow_up_id and notebook_id = p_notebook_id;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'invalidChange: follow-up % not found', v_follow_up_id;
  end if;

  return jsonb_build_object('ids', jsonb_build_object('followUpId', v_follow_up_id));
end;
$$;

create or replace function public._commit_clear_notebook(
  p_notebook_id uuid
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
begin
  delete from public.journal_entries where notebook_id = p_notebook_id;
  delete from public.entities where notebook_id = p_notebook_id;
  delete from public.relations where notebook_id = p_notebook_id;
  delete from public.follow_ups where notebook_id = p_notebook_id;
  delete from public.asked_questions where notebook_id = p_notebook_id;
  -- Derived data, not a source table: clearing the graph must also clear
  -- what it seeded for semantic recall, immediately and atomically — the
  -- 30-minute embed_orphan_prune cron sweep is a backstop for drift, not a
  -- substitute for this (today's delete-then-insert save leaves stale,
  -- still-searchable embeddings behind for up to 30 minutes; this fixes that).
  delete from public.entity_embeddings where notebook_id = p_notebook_id;
  return jsonb_build_object('ids', jsonb_build_object());
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. get_notebook_snapshot — the paired consistent read
--
-- Returns one domain-shaped JSON object in a single statement: the revision
-- callers must pass back as expectedRevision on their next commit, plus a
-- JournalState identical in shape to what both clients already model. No
-- client hand-writes source_id/target_id -> source/target translation
-- anymore — this function is the only place that does it.
-- ────────────────────────────────────────────────────────────
create or replace function public.get_notebook_snapshot(
  p_notebook_id uuid
) returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when nb.id is null then null else jsonb_build_object(
    'notebookId', nb.id,
    'revision', nb.revision,
    'state', jsonb_build_object(
      'entries', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', e.id, 'text', e.text, 'createdAt', e.created_at,
          'entityIds', to_jsonb(e.entity_ids), 'relationIds', to_jsonb(e.relation_ids)
        ) order by e.created_at desc)
        from public.journal_entries e where e.notebook_id = nb.id
      ), '[]'::jsonb),
      'entities', coalesce((
        select jsonb_object_agg(en.id, jsonb_build_object(
          'id', en.id, 'name', en.name, 'type', en.type, 'description', en.description,
          'metadata', en.metadata, 'mentions', en.mentions,
          'firstSeen', en.first_seen, 'lastSeen', en.last_seen,
          'questions', case when en.questions is null then null else to_jsonb(en.questions) end
        ))
        from public.entities en where en.notebook_id = nb.id
      ), '{}'::jsonb),
      'relations', coalesce((
        select jsonb_object_agg(r.id, jsonb_build_object(
          'id', r.id, 'source', r.source_id, 'target', r.target_id, 'label', r.label,
          'metadata', r.metadata, 'createdAt', r.created_at, 'supersededAt', r.superseded_at
        ))
        from public.relations r where r.notebook_id = nb.id
      ), '{}'::jsonb),
      'followUps', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', f.id, 'question', f.question, 'reason', f.reason,
          'targetEntityIds', to_jsonb(f.target_entity_ids),
          'createdAt', f.created_at, 'answered', f.answered
        ) order by f.created_at desc)
        from public.follow_ups f where f.notebook_id = nb.id
      ), '[]'::jsonb),
      'askedQuestions', coalesce((
        select jsonb_agg(jsonb_build_object(
          'question', a.question, 'targetEntityIds', to_jsonb(a.target_entity_ids), 'askedAt', a.asked_at
        ) order by a.asked_at desc)
        from (
          select * from public.asked_questions where notebook_id = nb.id
          order by asked_at desc limit 30
        ) a
      ), '[]'::jsonb)
    )
  ) end
  from public.notebooks nb
  where nb.id = p_notebook_id and nb.user_id = auth.uid();
$$;

-- ────────────────────────────────────────────────────────────
-- 5. Grants
--
-- Only the two public entry points are callable by signed-in users. The
-- three _commit_* helpers are plain (non-DEFINER) functions with no grant to
-- anon/authenticated — reachable only from inside commit_notebook's DEFINER
-- context, never directly.
-- ────────────────────────────────────────────────────────────
revoke all on function public.commit_notebook(uuid, bigint, uuid, jsonb) from public, anon;
grant execute on function public.commit_notebook(uuid, bigint, uuid, jsonb) to authenticated;

revoke all on function public.get_notebook_snapshot(uuid) from public, anon;
grant execute on function public.get_notebook_snapshot(uuid) to authenticated;

revoke all on function public._commit_apply_turn(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public._commit_answer_follow_up(uuid, jsonb) from public, anon, authenticated;
revoke all on function public._commit_clear_notebook(uuid) from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 6. Cut the old direct-write path
--
-- Both clients are converted to commit_notebook/get_notebook_snapshot in
-- this same change (no dual-write, no fallback — see cutover rules in the
-- spec), and this app has no shipped builds yet, so there is no
-- already-in-the-wild client depending on direct child-table writes.
-- SELECT stays granted: RLS still scopes it to the owner, and nothing above
-- needs it revoked.
-- ────────────────────────────────────────────────────────────
revoke insert, update, delete on public.journal_entries from authenticated;
revoke insert, update, delete on public.entities from authenticated;
revoke insert, update, delete on public.relations from authenticated;
revoke insert, update, delete on public.follow_ups from authenticated;
revoke insert, update, delete on public.asked_questions from authenticated;
