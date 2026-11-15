-- Phase 2 (I2): a forget on one device must reach the user's other devices.
--
-- Each device keeps, on the phone, things the server cannot reach: the
-- "What Lumen shared" log (its speak entries carry real names), the opening
-- brief held with its audio, and the name map in the Keychain. When the
-- account forgets someone anywhere, the other phones have to find out.
--
-- This returns the only thing they need: how many people the caller has
-- forgotten and when the newest forget happened. The app stores the last
-- value it saw per account and cleans up when it goes up. No hash, slug or
-- name leaves the database; only the caller's own rows are counted.

create or replace function public.forgotten_marker()
returns table (forgotten_count bigint, latest_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  return query
    select count(*)::bigint, max(s.created_at)
      from public.entity_suppressions s
     where s.user_id = auth.uid()
       and s.kind = 'forgotten';
end;
$$;

revoke all on function public.forgotten_marker() from public, anon;
grant execute on function public.forgotten_marker() to authenticated;
