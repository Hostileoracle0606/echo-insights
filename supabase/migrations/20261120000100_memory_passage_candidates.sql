-- Search only currently saved, caller-owned journal entries. No passage text or
-- embeddings are persisted by this search, so Forget, edits and deletion cannot
-- leave a stale index behind. The bounded recent pool makes semantic search a
-- best-effort candidate search rather than a full-corpus vector index.
create function public.memory_passage_candidates(
  p_query text default '', p_ids uuid[] default '{}', p_exact boolean default false
) returns jsonb
language sql stable security invoker
set search_path = public, pg_temp
as $$
  with eligible as (
    select e.id, e.notebook_id, coalesce(e.context_text, e.text) as body,
           e.created_at, t.spoken_at
    from public.journal_entries e
    join public.notebooks n on n.id = e.notebook_id and n.user_id = auth.uid()
    left join lateral (
      select ct.spoken_at from public.conversation_turns ct
      where ct.user_id = auth.uid() and ct.notebook_id = e.notebook_id
        and ct.speaker = 'user' and ct.text = e.text and ct.spoken_at <= e.created_at
      order by ct.spoken_at desc limit 1
    ) t on true
    where auth.uid() is not null and e.user_id = auth.uid()
      and length(coalesce(e.context_text, e.text)) > 0
  ), selected as (
    (select *, 0 as priority from eligible where id = any(coalesce(p_ids, '{}')) limit 20)
    union all
    (select *, 1 as priority from eligible
     where not coalesce(p_exact, false)
       and exists (select 1 from regexp_split_to_table(lower(left(coalesce(p_query, ''), 1000)), '[^[:alnum:]]+') term
                   where length(term) >= 3 and to_tsvector('simple', body) @@ plainto_tsquery('simple', term))
       and not (id = any(coalesce(p_ids, '{}')))
     order by created_at desc, id limit 20)
    union all
    (select *, 2 as priority from eligible
     where not coalesce(p_exact, false) and not (id = any(coalesce(p_ids, '{}')))
     order by created_at desc, id limit 20)
  ), dedup as (
    select distinct on (id) * from selected order by id, priority
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'entryId', id, 'notebookId', notebook_id, 'text', body,
    'createdAt', created_at, 'spokenAt', spoken_at
  ) order by priority, created_at desc, id), '[]'::jsonb) from dedup;
$$;
revoke all on function public.memory_passage_candidates(text, uuid[], boolean) from public, anon;
grant execute on function public.memory_passage_candidates(text, uuid[], boolean) to authenticated;
