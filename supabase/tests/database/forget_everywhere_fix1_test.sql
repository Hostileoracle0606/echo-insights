-- pgTAP: LM-63 fix round 1. Ids are renamed by the entity's name, not by a
-- capitalised id; renamed entities are queued for a new embedding; the
-- backfill writes only rows whose redacted words differ. Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(17);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, summary, started_at, revision, conversation_mode) values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'N1', 'S', now(), 3, 'just_talk'),
  ('b2222222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'N', 'S', now(), 3, 'just_talk');

insert into public.entities (id, user_id, notebook_id, name, type, mentions, first_seen, last_seen) values
  ('will', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Will', 'person', 1, now(), now()),
  ('grace', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Grace', 'person', 1, now(), now()),
  ('mark', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Mark', 'person', 1, now(), now()),
  ('will-power', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'will power', 'concept', 1, now(), now()),
  ('good-will', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'good will', 'concept', 1, now(), now()),
  ('grace-period', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'grace period', 'concept', 1, now(), now()),
  ('mark-down', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'mark down', 'concept', 1, now(), now()),
  ('grace-hopper-prize', '11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'Grace Hopper Prize', 'event', 1, now(), now());

create function public._t_as(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true);
$$;

-- The embedding queue is configured, and empty before the forget.
select vault.create_secret('http://127.0.0.1:9/embed-entities', 'embed_entities_url');
select vault.create_secret('fix1-test-secret', 'embed_internal_secret');
delete from net.http_request_queue;

select public._t_as('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select public.forget_entity('will') is not null as w \gset
select public.forget_entity('grace') is not null as g \gset
select public.forget_entity('mark') is not null as m \gset
reset role;

-- ── embeddings (before any insert could queue one): renamed entities are queued again ──────────────────────────
select ok(exists (select 1 from net.http_request_queue q
                  where convert_from(q.body, 'UTF8')::jsonb ->> 'notebookId' = 'a1111111-0000-0000-0000-000000000001'),
  'embeddings: the notebook of a renamed entity is queued for embedding');

-- ── ids: by the name, with the name rules ──────────────────────────────────
select is((select array_agg(id order by id) from public.entities where user_id = '11111111-1111-1111-1111-111111111111'),
  array['good-will', 'grace-period', 'mark-down', 'someone-hopper-prize', 'will-power'],
  'ids: a lowercase concept keeps its id; a capitalised name that is hers is renamed');
select is((select name from public.entities where id = 'will-power'), 'will power', 'ids: will power is untouched');
select is((select name from public.entities where id = 'good-will'), 'good will', 'ids: good will is untouched');
select is((select name from public.entities where id = 'grace-period'), 'grace period', 'ids: grace period is untouched');
select is((select name from public.entities where id = 'mark-down'), 'mark down', 'ids: mark down is untouched');
select is((select name from public.entities where id = 'someone-hopper-prize'), 'someone Hopper Prize',
  'ids: Grace Hopper Prize is renamed with its name');

-- On commit, the same rule.
select public._t_as('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select public.commit_notebook('a1111111-0000-0000-0000-000000000001',
  (public.get_notebook_snapshot('a1111111-0000-0000-0000-000000000001') ->> 'revision')::bigint, gen_random_uuid(),
  jsonb_build_object('kind', 'applyTurn',
    'entry', jsonb_build_object('text', 'Grace period ends. Mark Down Street. Will power helps.',
      'entityIds', jsonb_build_array('grace-period', 'mark-down-street', 'will-power')),
    'entities', jsonb_build_array(
      jsonb_build_object('id', 'grace-period', 'name', 'grace period', 'type', 'concept', 'mentions', 2),
      jsonb_build_object('id', 'mark-down-street', 'name', 'Mark Down Street', 'type', 'place', 'mentions', 1),
      jsonb_build_object('id', 'will-power', 'name', 'will power', 'type', 'concept', 'mentions', 2)),
    'relations', '[]'::jsonb)) as c \gset
reset role;
select is(:'c'::jsonb ->> 'status', 'committed', 'commit: lands');
select is(:'c'::jsonb -> 'suppressedIds', '["mark-down-street"]'::jsonb,
  'commit: only the id whose capitalised name is hers is renamed');
select ok(exists (select 1 from public.entities where id = 'someone-down-street'), 'commit: it is stored under the new id');
select ok(exists (select 1 from public.entities where id = 'grace-period' and mentions = 2), 'commit: grace-period keeps its id');

-- ── the backfill writes only rows that change ──────────────────────────────
-- U2 forgot Dana before context_text existed: rows are written first, the
-- suppression afterwards, as on a database being migrated.
insert into public.journal_entries (user_id, notebook_id, text, created_at, entity_ids, relation_ids) values
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Dana Whit called.', now(), '{}', '{}'),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Nothing about her.', now(), '{}', '{}'),
  ('22222222-2222-2222-2222-222222222222', 'b2222222-0000-0000-0000-000000000001', 'Lunch with Dana Whit.', now(), '{}', '{}');
insert into public.conversation_turns (notebook_id, turn_id, user_id, speaker, text, spoken_at)
  select 'b2222222-0000-0000-0000-000000000001', 't' || g, '22222222-2222-2222-2222-222222222222', 'user',
         case when g % 3 = 0 then 'Dana Whit again.' else 'Weather talk.' end, now()
  from generate_series(1, 9) g;
select public._suppression_key('22222222-2222-2222-2222-222222222222') is not null as k \gset
insert into public.entity_suppressions (user_id, entity_hash, kind, match_inside, name_words)
  values ('22222222-2222-2222-2222-222222222222', public._suppression_hash('22222222-2222-2222-2222-222222222222', 'dana-whit'),
          'forgotten', false, 2);
select is((select count(*)::int from public.journal_entries where context_text is not null
           and user_id = '22222222-2222-2222-2222-222222222222'), 0, 'backfill: nothing precomputed yet');

select is(public._backfill_context_text(2), 5, 'backfill: 2 entries and 3 turns change, in batches of 2');
select is((select array_agg(context_text order by text) from public.journal_entries
           where user_id = '22222222-2222-2222-2222-222222222222' and context_text is not null),
  array['someone called.', 'Lunch with someone.'], 'backfill: the entries that name her are redacted');
select is((select count(*)::int from public.conversation_turns
           where user_id = '22222222-2222-2222-2222-222222222222' and context_text = 'someone again.'), 3,
  'backfill: so are the turns');
select is(public._backfill_context_text(2), 0, 'backfill: a second run writes nothing');
select is((select count(*)::int from public.conversation_turns
           where user_id = '22222222-2222-2222-2222-222222222222' and context_text is null), 6,
  'backfill: rows that never named her stay null');

select * from finish();
rollback;
