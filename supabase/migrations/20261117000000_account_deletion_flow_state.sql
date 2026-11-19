-- Account deletion (LM-117): auth.flow_state.
--
-- Every auth table with a user_id (sessions, refresh_tokens, identities,
-- mfa_factors, one_time_tokens, oauth_*, webauthn_*) cascades from
-- auth.users, directly or through auth.sessions. auth.flow_state does not:
-- its user_id has no foreign key. Its rows are short-lived PKCE hand-offs but
-- carry the provider's access and refresh tokens, so we purge them in the
-- same BEFORE DELETE trigger as the rate limits.
--
-- The flow_state purge is BEST-EFFORT. This trigger runs inside the
-- auth.users delete, so an error here would abort the whole account deletion.
-- auth.flow_state is a GoTrue-owned table and we cannot be sure from here that
-- the function owner may delete from it on the hosted project, so that one
-- statement is wrapped: on failure it raises a warning (no user id) and the
-- deletion proceeds. A leftover short-lived PKCE row is cheaper than a blocked
-- deletion. To be checked on staging at LM-120. The rate-limit delete stays
-- strict.
--
-- Function name is unchanged (it is the on_auth_user_deleted trigger target),
-- but it now purges both retrieve_rate_limits and auth.flow_state.
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

  begin
    delete from auth.flow_state where user_id = old.id;
  exception when others then
    raise warning 'purge of auth.flow_state skipped: % (%)', sqlerrm, sqlstate;
  end;

  return old;
end;
$$;

revoke all on function public.purge_deleted_user_rate_limits() from public, anon, authenticated;

comment on function public.purge_deleted_user_rate_limits() is
  'BEFORE DELETE on auth.users: purges retrieve_rate_limits (strict) and auth.flow_state (best-effort).';
