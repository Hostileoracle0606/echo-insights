-- pgTAP: commit_notebook accepts the payload the Flutter client actually sends.
-- Run: supabase test db
--
-- The Dart client serialises Entity.questions with no includeIfNull, so an
-- entity without open questions arrives as `"questions": null` (a JSON null,
-- not a missing key). jsonb_array_elements_text on that null raised "cannot
-- extract elements from a scalar", commit_notebook turned it into
-- commitFailed, and no entity ever reached the database.
create extension if not exists pgtap;

begin;
select plan(6);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');

insert into public.notebooks (id, user_id, title, started_at)
values ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'Test NB', now());

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- ── 1. "questions": null on every entity, as the app sends it ──────────────
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 0::bigint, 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
  '{
    "kind": "applyTurn",
    "entry": {"text": "Priya Raman is leading Atlas.", "entityIds": ["priya_raman","atlas"], "relationIds": ["priya_raman__leads__atlas"]},
    "entities": [
      {"id":"priya_raman","name":"Priya Raman","type":"person","description":null,"metadata":{},"mentions":1,"firstSeen":"2026-10-28T01:52:40.123456Z","lastSeen":"2026-10-28T01:52:40.123456Z","questions":null},
      {"id":"atlas","name":"Atlas","type":"project","description":null,"metadata":{},"mentions":1,"firstSeen":"2026-10-28T01:52:40.123456Z","lastSeen":"2026-10-28T01:52:40.123456Z","questions":null}
    ],
    "relations": [
      {"id":"priya_raman__leads__atlas","source":"priya_raman","target":"atlas","label":"leads","metadata":{},"createdAt":"2026-10-28T01:52:40.123456Z","supersededAt":null}
    ]
  }'::jsonb
) as result_1 \gset

select is(:'result_1'::jsonb ->> 'status', 'committed', 'null questions: status = committed');
select is((select count(*)::int from public.entities where notebook_id = '33333333-3333-3333-3333-333333333333'), 2, 'null questions: both entities inserted');
select is((select questions from public.entities where id = 'atlas'), null::text[], 'null questions: stored as SQL null');

-- ── 2. the upsert path: same entity again, questions still null ────────────
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 1::bigint, 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
  '{
    "kind": "applyTurn",
    "entry": {"text": "Atlas ships Friday.", "entityIds": ["atlas"], "relationIds": []},
    "entities": [
      {"id":"atlas","name":"Atlas","type":"project","description":"ships Friday","metadata":{},"mentions":2,"firstSeen":"2026-10-28T01:52:40.123456Z","lastSeen":"2026-10-28T01:53:40.123456Z","questions":null}
    ],
    "relations": []
  }'::jsonb
) as result_2 \gset

select is(:'result_2'::jsonb ->> 'status', 'committed', 'null questions on update: status = committed');
select is((select mentions from public.entities where id = 'atlas'), 2, 'null questions on update: mentions updated');

-- ── 3. a real questions array still lands ──────────────────────────────────
select public.commit_notebook(
  '33333333-3333-3333-3333-333333333333'::uuid, 2::bigint, 'aaaaaaaa-0000-0000-0000-000000000003'::uuid,
  '{
    "kind": "applyTurn",
    "entry": {"text": "Not sure Priya will make it.", "entityIds": ["priya_raman"], "relationIds": []},
    "entities": [
      {"id":"priya_raman","name":"Priya Raman","type":"person","metadata":{},"mentions":2,"firstSeen":"2026-10-28T01:52:40.123456Z","lastSeen":"2026-10-28T01:54:40.123456Z","questions":["Will Priya make the deadline?"]}
    ],
    "relations": []
  }'::jsonb
) as result_3 \gset

select is((select questions from public.entities where id = 'priya_raman'), array['Will Priya make the deadline?'], 'questions array: stored');

select * from finish();
rollback;
