-- Account deletion (App Store Guideline 5.1.1(v)).
--
-- Every user-data table already cascades from auth.users(id), directly or via
-- notebooks, so deleting the auth user (auth.admin.deleteUser in the
-- delete-account edge function) removes it all. The one exception is
-- retrieve_rate_limits: it is keyed by the text scopes 'user:<uid>' and
-- 'notebook:<id>' with no foreign key, so its counters would outlive the
-- account. This trigger purges them in the same transaction as the delete.
--
-- BEFORE DELETE so the user's notebooks still exist when their scopes are
-- collected (the notebook cascade runs after the auth row is removed).
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
  return old;
end;
$$;

revoke all on function public.purge_deleted_user_rate_limits() from public, anon, authenticated;

create trigger on_auth_user_deleted
  before delete on auth.users
  for each row execute procedure public.purge_deleted_user_rate_limits();
