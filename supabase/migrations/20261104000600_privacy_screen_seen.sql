-- LM-53: profiles.privacy_screen_seen_at — when the signed-in user first saw
-- the "Who hears you" screen (shown once, on the first mic tap).
--
-- The column is read through the owner-select policy and written only by
-- mark_privacy_screen_seen(): table-level INSERT/UPDATE are replaced by
-- column grants that leave it out, so a client cannot set or clear it.
alter table public.profiles add column privacy_screen_seen_at timestamptz;

revoke insert, update on public.profiles from anon, authenticated;
grant insert (user_id, display_name) on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;

-- SECURITY DEFINER, no user parameter: it stamps the caller's own row. A
-- user without a profile row (created before the signup trigger) gets one.
-- Idempotent: the first time stays.
create or replace function public.mark_privacy_screen_seen()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  insert into public.profiles (user_id, privacy_screen_seen_at)
  values (auth.uid(), now())
  on conflict (user_id) do update
    set privacy_screen_seen_at = coalesce(
      public.profiles.privacy_screen_seen_at, excluded.privacy_screen_seen_at);
end;
$$;

revoke all on function public.mark_privacy_screen_seen() from public, anon;
grant execute on function public.mark_privacy_screen_seen() to authenticated;
