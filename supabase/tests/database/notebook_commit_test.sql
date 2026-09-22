-- pgTAP tests for the Notebook Commit module (commit_notebook / get_notebook_snapshot).
-- Run: supabase test db
--
-- Everything happens inside one transaction that is rolled back at the end,
-- so this test file never leaves residue in the database it runs against.
create extension if not exists pgtap;

begin;
select plan(40);

-- ── fixtures: two users, one notebook owned by user A ──────────────────────
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into public.notebooks (id, user_id, title, started_at)
values ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'Test NB', now());

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── 1. successful applyTurn ─────────────────────────────────────────────────
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 0::bigint, 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
  '{
    "kind": "applyTurn",
    "entry": {"text": "Had coffee with Maya about Atlas.", "entityIds": ["maya","atlas"], "relationIds": ["maya__works_on__atlas"]},
    "entities": [
      {"id":"maya","name":"Maya","type":"person","metadata":{},"mentions":1,"firstSeen":"2026-08-21T00:00:00Z","lastSeen":"2026-08-21T00:00:00Z"},
      {"id":"atlas","name":"Atlas","type":"project","metadata":{},"mentions":1,"firstSeen":"2026-08-21T00:00:00Z","lastSeen":"2026-08-21T00:00:00Z"}
    ],
    "relations": [
      {"id":"maya__works_on__atlas","source":"maya","target":"atlas","label":"works_on","metadata":{},"createdAt":"2026-08-21T00:00:00Z"}
    ]
  }'::jsonb
) as result_1 \gset

select is(:'result_1'::jsonb ->> 'status', 'committed', 'successful turn: status = committed');
select is((:'result_1'::jsonb ->> 'revision')::int, 1, 'successful turn: revision becomes 1');
select ok(:'result_1'::jsonb -> 'ids' ->> 'entryId' is not null, 'successful turn: entryId is a real (UUID) id');
select is((select count(*)::int from public.entities where notebook_id = '33333333-3333-3333-3333-333333333333'), 2, 'successful turn: both entities inserted');
select is((select count(*)::int from public.relations where notebook_id = '33333333-3333-3333-3333-333333333333'), 1, 'successful turn: relation inserted');
select is((select count(*)::int from public.journal_entries where notebook_id = '33333333-3333-3333-3333-333333333333'), 1, 'successful turn: entry inserted');
select is((select entity_count from public.notebooks where id = '33333333-3333-3333-3333-333333333333'), 2, 'successful turn: notebooks.entity_count recomputed');

-- ── 2. rejected: invalid entity type, nothing written ───────────────────────
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 1::bigint, 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
  '{"kind":"applyTurn","entry":{"text":"x","entityIds":["bad"],"relationIds":[]},"entities":[{"id":"bad","name":"Bad","type":"not_a_real_type","metadata":{},"mentions":1,"firstSeen":"2026-08-21T00:00:00Z","lastSeen":"2026-08-21T00:00:00Z"}],"relations":[]}'::jsonb
) as result_2 \gset

select is(:'result_2'::jsonb ->> 'status', 'rejected', 'rejected data: status = rejected');
select is(:'result_2'::jsonb ->> 'code', 'invalidChange', 'rejected data: code = invalidChange');
select is((select revision from public.notebooks where id = '33333333-3333-3333-3333-333333333333'), 1::bigint, 'rejected data: revision unchanged');
select is((select count(*)::int from public.entities where notebook_id = '33333333-3333-3333-3333-333333333333' and id = 'bad'), 0, 'rejected data: bad row never inserted');

-- ── 4. duplicate request: exact replay, no re-application ──────────────────
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 0::bigint, 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
  '{
    "kind": "applyTurn",
    "entry": {"text": "Had coffee with Maya about Atlas.", "entityIds": ["maya","atlas"], "relationIds": ["maya__works_on__atlas"]},
    "entities": [
      {"id":"maya","name":"Maya","type":"person","metadata":{},"mentions":1,"firstSeen":"2026-08-21T00:00:00Z","lastSeen":"2026-08-21T00:00:00Z"},
      {"id":"atlas","name":"Atlas","type":"project","metadata":{},"mentions":1,"firstSeen":"2026-08-21T00:00:00Z","lastSeen":"2026-08-21T00:00:00Z"}
    ],
    "relations": [
      {"id":"maya__works_on__atlas","source":"maya","target":"atlas","label":"works_on","metadata":{},"createdAt":"2026-08-21T00:00:00Z"}
    ]
  }'::jsonb
) as result_4 \gset

select is(:'result_4'::jsonb, :'result_1'::jsonb, 'duplicate request: replay returns the identical stored outcome');
select is((select count(*)::int from public.journal_entries where notebook_id = '33333333-3333-3333-3333-333333333333'), 1, 'duplicate request: no duplicate entry row');
select is((select revision from public.notebooks where id = '33333333-3333-3333-3333-333333333333'), 1::bigint, 'duplicate request: revision not bumped again');

-- ── 5. same request id, different payload -> requestIdReused ───────────────
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 1::bigint, 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
  '{"kind":"applyTurn","entry":{"text":"DIFFERENT TEXT","entityIds":[],"relationIds":[]},"entities":[],"relations":[]}'::jsonb
) as result_5 \gset

select is(:'result_5'::jsonb ->> 'status', 'rejected', 'reused id, changed payload: status = rejected');
select is(:'result_5'::jsonb ->> 'code', 'requestIdReused', 'reused id, changed payload: code = requestIdReused');

-- ── 7. wrong owner: no disclosure, no mutation ──────────────────────────────
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 1::bigint, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid,
  '{"kind":"clearNotebook"}'::jsonb
) as result_7 \gset

select is(:'result_7'::jsonb ->> 'status', 'rejected', 'wrong owner: status = rejected');
select is(:'result_7'::jsonb ->> 'code', 'notFound', 'wrong owner: code = notFound (no ownership info leaked)');
select is((select count(*)::int from public.entities where notebook_id = '33333333-3333-3333-3333-333333333333'), 2, 'wrong owner: notebook data left untouched');
select ok(public.get_notebook_snapshot('33333333-3333-3333-3333-333333333333'::uuid) is null, 'wrong owner: snapshot read also discloses nothing');

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── 3. concurrent revision: exactly one of two racers wins ──────────────────
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 1::bigint, 'cccccccc-0000-0000-0000-000000000001'::uuid,
  '{"kind":"applyTurn","entry":{"text":"first racer","entityIds":[],"relationIds":[]},"entities":[],"relations":[]}'::jsonb
) as result_3a \gset
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 1::bigint, 'cccccccc-0000-0000-0000-000000000002'::uuid,
  '{"kind":"applyTurn","entry":{"text":"second racer","entityIds":[],"relationIds":[]},"entities":[],"relations":[]}'::jsonb
) as result_3b \gset

select ok(
  (:'result_3a'::jsonb ->> 'status' = 'committed' and :'result_3b'::jsonb ->> 'status' = 'conflict')
  or
  (:'result_3b'::jsonb ->> 'status' = 'committed' and :'result_3a'::jsonb ->> 'status' = 'conflict'),
  'concurrent revision: exactly one commit wins, the other gets conflict'
);

-- ── 6. mid-write failure: a genuine DB error rolls back everything ─────────
select revision from public.notebooks where id = '33333333-3333-3333-3333-333333333333' \gset current_

create or replace function public._test_boom() returns trigger language plpgsql as $$ begin raise exception 'boom-injected-failure'; end $$;
create trigger _test_boom_trigger before insert on public.relations for each row execute function public._test_boom();

select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, :current_revision::bigint, 'dddddddd-0000-0000-0000-000000000001'::uuid,
  '{"kind":"applyTurn","entry":{"text":"rollback me","entityIds":["ghost"],"relationIds":["ghost__x__atlas"]},"entities":[{"id":"ghost","name":"Ghost","type":"person","metadata":{},"mentions":1,"firstSeen":"2026-08-21T00:00:00Z","lastSeen":"2026-08-21T00:00:00Z"}],"relations":[{"id":"ghost__x__atlas","source":"ghost","target":"atlas","label":"x","metadata":{},"createdAt":"2026-08-21T00:00:00Z"}]}'::jsonb
) as result_6 \gset

select is(:'result_6'::jsonb ->> 'status', 'rejected', 'mid-write failure: status = rejected');
select is(:'result_6'::jsonb ->> 'code', 'commitFailed', 'mid-write failure: code = commitFailed');
select is((select count(*)::int from public.entities where notebook_id = '33333333-3333-3333-3333-333333333333' and id = 'ghost'), 0, 'mid-write failure: earlier insert in the same commit was rolled back too');
select is((select revision from public.notebooks where id = '33333333-3333-3333-3333-333333333333'), :current_revision::bigint, 'mid-write failure: revision not bumped');
select is((select count(*)::int from public.notebook_commit_requests where request_id = 'dddddddd-0000-0000-0000-000000000001'), 0, 'mid-write failure: no idempotency record left behind');

drop trigger _test_boom_trigger on public.relations;
drop function public._test_boom();

-- ── 8. clearNotebook: every child row and derived embedding, atomically ────
insert into public.entity_embeddings (notebook_id, entity_id, user_id, embedding, embedding_model, content_hash)
values ('33333333-3333-3333-3333-333333333333', 'atlas', '11111111-1111-1111-1111-111111111111', array_fill(0.1, array[384])::vector, 'test@1', 'hash1');

select revision from public.notebooks where id = '33333333-3333-3333-3333-333333333333' \gset pre_clear_

select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, :pre_clear_revision::bigint, 'eeeeeeee-0000-0000-0000-000000000001'::uuid,
  '{"kind":"clearNotebook"}'::jsonb
) as result_8 \gset

select is(:'result_8'::jsonb ->> 'status', 'committed', 'clearNotebook: status = committed');
select is((select count(*)::int from public.journal_entries where notebook_id = '33333333-3333-3333-3333-333333333333'), 0, 'clearNotebook: entries gone');
select is((select count(*)::int from public.entities where notebook_id = '33333333-3333-3333-3333-333333333333'), 0, 'clearNotebook: entities gone');
select is((select count(*)::int from public.relations where notebook_id = '33333333-3333-3333-3333-333333333333'), 0, 'clearNotebook: relations gone');
select is((select count(*)::int from public.entity_embeddings where notebook_id = '33333333-3333-3333-3333-333333333333'), 0, 'clearNotebook: derived embeddings gone too');


-- ── 9. finalized-turn replay: one request id survives a conflict rebase ─────
--
-- The client mints ONE commit request id per finalized transcript and reuses
-- it for every attempt at that turn — including the attempt made after a
-- revision conflict forced a rebase onto a fresh snapshot. That is only safe
-- because a conflict performs no write and therefore records no ledger row.
-- These assertions pin that property down, since the whole client-side
-- recovery design depends on it.

select revision from public.notebooks where id = '33333333-3333-3333-3333-333333333333' \gset replay_

-- 9a. a conflicting attempt with a fresh request id leaves no ledger trace
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid,
  (:replay_revision::bigint + 99),
  'ffffffff-0000-0000-0000-000000000001'::uuid,
  '{"kind":"applyTurn","entry":{"text":"Rebased turn one.","entityIds":["nina"],"relationIds":[]},
    "entities":[{"id":"nina","name":"Nina","type":"person","metadata":{},"mentions":1,"firstSeen":"2026-09-10T00:00:00Z","lastSeen":"2026-09-10T00:00:00Z"}],
    "relations":[]}'::jsonb
) as result_9a \gset

select is(:'result_9a'::jsonb ->> 'status', 'conflict', 'conflict rebase: stale revision conflicts');
select is(
  (select count(*)::int from public.notebook_commit_requests
     where request_id = 'ffffffff-0000-0000-0000-000000000001'),
  0,
  'conflict rebase: a conflict records NO idempotency row'
);

-- 9b. the SAME request id now commits against the reloaded revision
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid,
  :replay_revision::bigint,
  'ffffffff-0000-0000-0000-000000000001'::uuid,
  '{"kind":"applyTurn","entry":{"text":"Rebased turn one.","entityIds":["nina"],"relationIds":[]},
    "entities":[{"id":"nina","name":"Nina","type":"person","metadata":{},"mentions":1,"firstSeen":"2026-09-10T00:00:00Z","lastSeen":"2026-09-10T00:00:00Z"}],
    "relations":[]}'::jsonb
) as result_9b \gset

select is(:'result_9b'::jsonb ->> 'status', 'committed', 'conflict rebase: the ORIGINAL request id commits after reload');
select is((:'result_9b'::jsonb ->> 'revision')::int, (:replay_revision::int + 1), 'conflict rebase: revision advances by exactly one');

-- 9c. a second pending turn commits next, in order, with its own id
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid,
  (:replay_revision::bigint + 1),
  'ffffffff-0000-0000-0000-000000000002'::uuid,
  '{"kind":"applyTurn","entry":{"text":"Rebased turn two.","entityIds":["omar"],"relationIds":[]},
    "entities":[{"id":"omar","name":"Omar","type":"person","metadata":{},"mentions":1,"firstSeen":"2026-09-10T00:00:01Z","lastSeen":"2026-09-10T00:00:01Z"}],
    "relations":[]}'::jsonb
) as result_9c \gset

select is(:'result_9c'::jsonb ->> 'status', 'committed', 'conflict rebase: the second pending turn commits after the first');
select is(
  (select count(*)::int from public.entities
     where notebook_id = '33333333-3333-3333-3333-333333333333' and id in ('nina','omar')),
  2,
  'conflict rebase: both replayed turns applied exactly once'
);

-- ── 10. lost response: the identical retry replays, it does not re-apply ────
--
-- The server committed but the response never reached the client. The client
-- retries the byte-identical request with the same id; the ledger must hand
-- back the stored outcome without touching the graph again.
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid,
  :replay_revision::bigint,
  'ffffffff-0000-0000-0000-000000000001'::uuid,
  '{"kind":"applyTurn","entry":{"text":"Rebased turn one.","entityIds":["nina"],"relationIds":[]},
    "entities":[{"id":"nina","name":"Nina","type":"person","metadata":{},"mentions":1,"firstSeen":"2026-09-10T00:00:00Z","lastSeen":"2026-09-10T00:00:00Z"}],
    "relations":[]}'::jsonb
) as result_10 \gset

select is(:'result_10'::jsonb ->> 'status', 'committed', 'lost response: identical retry replays the committed outcome');
select is((:'result_10'::jsonb ->> 'revision')::int, (:replay_revision::int + 1), 'lost response: replay returns the ORIGINAL revision, not a new one');
select is(
  (select mentions from public.entities
     where notebook_id = '33333333-3333-3333-3333-333333333333' and id = 'nina'),
  1,
  'lost response: mention count not double-applied by the retry'
);

select * from finish();
rollback;
