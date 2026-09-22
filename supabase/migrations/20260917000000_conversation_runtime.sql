-- Service-only conversation inbox and embedded transactional outbox. End-user
-- identity is established by the AWS authorizer, never by a request body.
create table public.conversation_runtime_sessions (
  id uuid primary key,
  notebook_id uuid not null references public.notebooks(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  mode text not null check (mode in ('wiki', 'granular')),
  document jsonb,
  accepted bigint not null default 0,
  consumed bigint not null default 0,
  lease uuid,
  lease_until timestamptz,
  next_run timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create table public.conversation_runtime_inbox (
  session_id uuid not null references public.conversation_runtime_sessions(id) on delete cascade,
  sequence bigint not null check (sequence > 0),
  event_id uuid not null,
  observation jsonb not null,
  primary key (session_id, sequence),
  unique (session_id, event_id)
);
create index conversation_runtime_due on public.conversation_runtime_sessions(next_run);
alter table public.conversation_runtime_sessions enable row level security;
alter table public.conversation_runtime_inbox enable row level security;
revoke all on public.conversation_runtime_sessions, public.conversation_runtime_inbox from anon, authenticated;

create function public.conversation_runtime(p_op text, p_args jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s public.conversation_runtime_sessions%rowtype;
  e jsonb;
  prior public.conversation_runtime_inbox%rowtype;
  sid uuid := (p_args->>'sessionId')::uuid;
  uid uuid := (p_args->>'userId')::uuid;
  doc jsonb;
  result jsonb;
begin
  if p_op = 'due' then
    return coalesce((select jsonb_agg(id) from (
      select id from conversation_runtime_sessions
      where next_run <= now() and (lease_until is null or lease_until < now())
      order by next_run limit 100
    ) due), '[]');
  end if;
  if p_op = 'start' then
    if not exists(select 1 from notebooks where id = (p_args->>'notebookId')::uuid and user_id = uid) then
      raise exception 'notFound';
    end if;
    if (select count(*) from conversation_runtime_sessions where user_id = uid and created_at > now() - interval '1 hour') >= 100
       and not exists(select 1 from conversation_runtime_sessions where id = sid and user_id = uid) then
      raise exception 'rateLimited';
    end if;
    insert into conversation_runtime_sessions(id, notebook_id, user_id, device_id, mode)
    values(sid, (p_args->>'notebookId')::uuid, uid, (p_args->>'deviceId')::uuid, p_args->>'mode')
    on conflict(id) do nothing;
  end if;
  select * into s from conversation_runtime_sessions where id = sid for update;
  if not found then raise exception 'notFound'; end if;
  if p_op in ('start', 'get', 'append') then
    if s.user_id is distinct from uid or s.notebook_id is distinct from (p_args->>'notebookId')::uuid then
      raise exception 'notFound';
    end if;
  end if;
  if p_op in ('start', 'append') and s.device_id is distinct from (p_args->>'deviceId')::uuid then
    raise exception 'deviceMismatch';
  end if;
  if p_op = 'start' and s.mode is distinct from p_args->>'mode' then raise exception 'sessionIdReused'; end if;
  if p_op = 'append' then
    if jsonb_typeof(p_args->'events') <> 'array' or jsonb_array_length(p_args->'events') not between 1 and 64
       or octet_length(p_args::text) > 262144 then raise exception 'invalidRequest'; end if;
    for e in select value from jsonb_array_elements(p_args->'events') loop
      if (e->>'sequence')::bigint <= s.accepted then
        select * into prior from conversation_runtime_inbox where session_id = sid and sequence = (e->>'sequence')::bigint;
        if not found or prior.event_id is distinct from (e->>'id')::uuid or prior.observation is distinct from e->'observation' then
          raise exception 'eventIdReused';
        end if;
      else
        if (e->>'sequence')::bigint <> s.accepted + 1 then raise exception 'sequenceGap'; end if;
        if s.accepted - s.consumed >= 2048 then raise exception 'backpressure'; end if;
        insert into conversation_runtime_inbox values(sid, (e->>'sequence')::bigint, (e->>'id')::uuid, e->'observation');
        s.accepted := s.accepted + 1;
      end if;
    end loop;
    update conversation_runtime_sessions set accepted = s.accepted, next_run = now() where id = sid;
    return jsonb_build_object('accepted', s.accepted);
  end if;
  if p_op = 'claim' then
    if s.lease_until > clock_timestamp() then return null; end if;
    s.lease := (p_args->>'lease')::uuid;
    update conversation_runtime_sessions set lease = s.lease, lease_until = clock_timestamp() + interval '90 seconds' where id = sid;
  end if;
  if p_op in ('save', 'release', 'commit') then
    if s.lease is distinct from (p_args->>'lease')::uuid or s.lease_until <= clock_timestamp() then
      raise exception 'leaseLost';
    end if;
  end if;
  if p_op = 'save' then
    doc := p_args->'document';
    if (doc->>'version')::int <> 1 or (doc->>'cursor')::bigint < s.consumed
      or (doc->>'cursor')::bigint > s.accepted then raise exception 'invalidCheckpoint'; end if;
    update conversation_runtime_sessions set document = doc, consumed = (doc->>'cursor')::bigint,
      lease_until = clock_timestamp() + interval '90 seconds',
      next_run = case when accepted > (doc->>'cursor')::bigint then now() else coalesce(
        (select min(to_timestamp((j->>'due')::double precision / 1000)) from jsonb_array_elements(doc->'jobs') j),
        'infinity'::timestamptz) end
      where id = sid;
    return 'true';
  end if;
  if p_op = 'release' then
    update conversation_runtime_sessions set lease = null, lease_until = null where id = sid;
    return 'true';
  end if;
  if p_op in ('snapshot', 'commit') then
    -- Identity comes from the stored owned session. This RPC is executable
    -- only by service_role, never by mobile/web tokens.
    perform set_config('request.jwt.claim.sub', s.user_id::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', s.user_id, 'role', 'authenticated')::text, true);
    if p_op = 'snapshot' then return get_notebook_snapshot(s.notebook_id); end if;
    return commit_notebook(s.notebook_id, (p_args->>'expectedRevision')::bigint,
      (p_args->>'requestId')::uuid, p_args->'change');
  end if;
  if p_op in ('start', 'get', 'claim', 'read') then
    select coalesce(jsonb_agg(jsonb_build_object('sequence', sequence, 'id', event_id, 'observation', observation) order by sequence), '[]')
      into result from (select * from conversation_runtime_inbox where session_id = sid and sequence > s.consumed order by sequence limit 64) i;
    return jsonb_build_object('sessionId', s.id, 'notebookId', s.notebook_id, 'userId', s.user_id,
      'mode', s.mode, 'accepted', s.accepted, 'document', s.document, 'events', result);
  end if;
  raise exception 'invalidOperation';
end $$;
revoke all on function public.conversation_runtime(text,jsonb) from public, anon, authenticated;
grant execute on function public.conversation_runtime(text,jsonb) to service_role;
