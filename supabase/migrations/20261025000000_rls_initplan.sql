-- RLS policies evaluate auth.uid() once per query, not once per row.
--
-- Written as `auth.uid() = user_id`, Postgres inlines auth.uid() (a
-- current_setting call plus a JSON parse) and re-evaluates it for every row
-- it filters. Wrapped as `(select auth.uid())` it becomes an init plan,
-- evaluated once. Same rows allowed, same roles, same permissive flags;
-- only the expressions change (ALTER POLICY keeps everything else).
-- Measured: a 60k-row RLS-filtered scan went from 45 ms to 15 ms.
-- See docs/complexity-audit.md (#5) and docs/performance-fixes.md.

alter policy "owner select" on public.profiles using ((select auth.uid()) = user_id);
alter policy "owner insert" on public.profiles with check ((select auth.uid()) = user_id);
alter policy "owner update" on public.profiles using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter policy "owner delete" on public.profiles using ((select auth.uid()) = user_id);

alter policy "owner select" on public.notebooks using ((select auth.uid()) = user_id);
alter policy "owner insert" on public.notebooks with check ((select auth.uid()) = user_id);
alter policy "owner update" on public.notebooks using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter policy "owner delete" on public.notebooks using ((select auth.uid()) = user_id);

alter policy "owner select" on public.journal_entries using ((select auth.uid()) = user_id);
alter policy "owner insert" on public.journal_entries with check ((select auth.uid()) = user_id);
alter policy "owner update" on public.journal_entries using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter policy "owner delete" on public.journal_entries using ((select auth.uid()) = user_id);

alter policy "owner select" on public.entities using ((select auth.uid()) = user_id);
alter policy "owner insert" on public.entities with check ((select auth.uid()) = user_id);
alter policy "owner update" on public.entities using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter policy "owner delete" on public.entities using ((select auth.uid()) = user_id);

alter policy "owner select" on public.relations using ((select auth.uid()) = user_id);
alter policy "owner insert" on public.relations with check ((select auth.uid()) = user_id);
alter policy "owner update" on public.relations using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter policy "owner delete" on public.relations using ((select auth.uid()) = user_id);

alter policy "owner select" on public.follow_ups using ((select auth.uid()) = user_id);
alter policy "owner insert" on public.follow_ups with check ((select auth.uid()) = user_id);
alter policy "owner update" on public.follow_ups using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter policy "owner delete" on public.follow_ups using ((select auth.uid()) = user_id);

alter policy "owner select" on public.asked_questions using ((select auth.uid()) = user_id);
alter policy "owner insert" on public.asked_questions with check ((select auth.uid()) = user_id);
alter policy "owner update" on public.asked_questions using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter policy "owner delete" on public.asked_questions using ((select auth.uid()) = user_id);

alter policy "owner select" on public.conversation_turns using ((select auth.uid()) = user_id);
alter policy "owner insert" on public.conversation_turns with check (
  (select auth.uid()) = user_id
  and exists (
    select 1 from public.notebooks n
    where n.id = notebook_id and n.user_id = (select auth.uid())
  )
);
alter policy "owner delete" on public.conversation_turns using ((select auth.uid()) = user_id);

alter policy "owner select" on public.entity_suppressions using ((select auth.uid()) = user_id);

alter policy "owner select" on public.session_cards using ((select auth.uid()) = user_id);
