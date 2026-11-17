-- Account deletion (LM-117): auth.flow_state.
--
-- Every auth table with a user_id (sessions, refresh_tokens, identities,
-- mfa_factors, one_time_tokens, oauth_*, webauthn_*) cascades from
-- auth.users, directly or through auth.sessions. auth.flow_state does not:
-- its user_id has no foreign key. Its rows are short-lived PKCE hand-offs but
-- carry the provider's access and refresh tokens, so they must not outlive the
-- account. Purge them in the same BEFORE DELETE trigger as the rate limits.
create or replace function public.purge_deleted_user_rate_limits() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.retrieve_rate_limits
  where scope = 'user:' || old.id::text
     or scope in (
       select 'notebook:' || n.id::text
       from public.notebooks n
       where n.user_id = old.id
     );
  delete from auth.flow_state where user_id = old.id;
  return old;
end;
$$;

revoke all on function public.purge_deleted_user_rate_limits() from public, anon, authenticated;
