-- pgTAP tests for LM-56: save_session_brief saves a brief with no audio (the
-- opening line couldn't be spoken); every other check still holds.
-- Run: supabase test db
create extension if not exists pgtap;

begin;
select plan(9);

insert into auth.users (id) values
  ('71111111-1111-1111-1111-111111111111'),
  ('72222222-2222-2222-2222-222222222222');
insert into public.notebooks (id, user_id, title, started_at, revision, entity_count) values
  ('c7111111-0000-0000-0000-000000000001', '71111111-1111-1111-1111-111111111111', 'A', now(), 4, 0);

set local role authenticated;
set local request.jwt.claim.sub = '71111111-1111-1111-1111-111111111111';

select is(
  public.save_session_brief('c7111111-0000-0000-0000-000000000001', 4,
    '{"focus":["The move"],"openingThread":"the move","openingLine":"Hey, how is the move going?"}'::jsonb,
    null, 24000),
  '{"status": "saved"}'::jsonb, 'null audio: the brief text is saved');
select is(public.get_session_brief()->'brief'->>'audioBase64', '',
  'get: no audio comes back as an empty string (the app plays the standard clip)');
select is(public.get_session_brief()->'brief'->'focus', '["The move"]'::jsonb,
  'get: the focus carries forward');

select is(
  public.save_session_brief('c7111111-0000-0000-0000-000000000001', 4,
    '{"focus":[],"openingThread":"","openingLine":"Hi"}'::jsonb, '', 24000),
  '{"status": "unchanged"}'::jsonb, 'empty audio at the same revision: the stored brief stays');

select throws_ok(
  $$ select public.save_session_brief('c7111111-0000-0000-0000-000000000001', 5,
       jsonb_build_object('focus', '[]'::jsonb, 'openingThread', '', 'openingLine', repeat('x', 161)),
       null, 24000) $$,
  '22023', null, 'no audio still needs a line of at most 160 characters');
select throws_ok(
  $$ select public.save_session_brief('c7111111-0000-0000-0000-000000000001', 5,
       '{"focus":[],"openingThread":"","openingLine":"Hi"}'::jsonb, null, 0) $$,
  '22023', null, 'no audio still needs a valid sample rate');
select throws_ok(
  $$ select public.save_session_brief('c7111111-0000-0000-0000-000000000001', 5,
       '{"focus":[],"openingThread":"","openingLine":"Hi"}'::jsonb, '@@@@', 24000) $$,
  '22023', null, 'audio that is not base64 is still refused');

set local request.jwt.claim.sub = '72222222-2222-2222-2222-222222222222';
select is(
  public.save_session_brief('c7111111-0000-0000-0000-000000000001', 9,
    '{"focus":[],"openingThread":"","openingLine":"Hi"}'::jsonb, null, 24000),
  '{"status": "rejected", "code": "notFound"}'::jsonb, 'no audio: another user still cannot save');

reset role;
set local role anon;
select throws_ok(
  $$ select public.save_session_brief('c7111111-0000-0000-0000-000000000001', 9,
       '{"focus":[],"openingThread":"","openingLine":"Hi"}'::jsonb, null, 24000) $$,
  '42501', null, 'anon still cannot call it');
reset role;

select * from finish();
rollback;
