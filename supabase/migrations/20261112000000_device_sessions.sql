-- LM-58: a device list with remote sign-out.
--
-- Supabase Auth has no client call that lists a user's sessions or ends one
-- other than "all others" (signOut(scope: others)). The only per-device route
-- is auth.sessions itself, which the app roles cannot read. These two
-- SECURITY DEFINER functions open exactly that, scoped to auth.uid() with no
-- user parameter, so no service key is involved and one user can never see or
-- end another's session.
--
-- Deleting the auth.sessions row cascades to auth.refresh_tokens (and
-- mfa_amr_claims), so the device can no longer refresh. Its current access
-- token still works until it expires (the project's JWT expiry, one hour by
-- default): that is how Supabase access tokens behave, not something this
-- function can shorten.
--
-- The IP address is deliberately not returned. user_agent is the only
-- device hint: the Dart client sends a generic one, so the app shows dates
-- and a coarse kind, not a device name.

create or replace function public.list_my_sessions()
returns table (
  id uuid,
  created_at timestamptz,
  last_active_at timestamptz,
  user_agent text,
  is_current boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_current uuid;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  begin
    v_current := (auth.jwt() ->> 'session_id')::uuid;
  exception when others then
    v_current := null;
  end;
  return query
    select s.id,
           s.created_at,
           greatest(s.updated_at, s.refreshed_at::timestamptz, s.created_at),
           s.user_agent,
           (s.id = v_current)
      from auth.sessions s
     where s.user_id = auth.uid()
       and (s.not_after is null or s.not_after > now())
     order by 3 desc nulls last;
end;
$$;

-- Ends one of the caller's other sessions. The caller's own session is
-- refused (false): signing out this device is the ordinary sign out. True
-- only when a row of the caller's was deleted; another user's id, or an id
-- that does not exist, is false and changes nothing.
create or replace function public.revoke_my_session(p_session_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current uuid;
  v_deleted int;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  begin
    v_current := (auth.jwt() ->> 'session_id')::uuid;
  exception when others then
    v_current := null;
  end;
  if p_session_id is null or p_session_id is not distinct from v_current then
    return false;
  end if;
  delete from auth.sessions s
   where s.id = p_session_id
     and s.user_id = auth.uid();
  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function public.list_my_sessions() from public, anon;
revoke all on function public.revoke_my_session(uuid) from public, anon;
grant execute on function public.list_my_sessions() to authenticated;
grant execute on function public.revoke_my_session(uuid) to authenticated;
