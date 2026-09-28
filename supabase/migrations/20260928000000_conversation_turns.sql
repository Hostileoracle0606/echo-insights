-- Both speakers' finalized turns, so a notebook reopened on any device shows
-- its conversation and Lumen can continue it with context. Turns are
-- immutable: written once at finalization (retries are ignored as duplicates)
-- and read when the notebook opens. The device's turn journal stays as the
-- offline cache for durable graph work.
create table public.conversation_turns (
  notebook_id uuid not null references public.notebooks(id) on delete cascade,
  turn_id     text not null check (char_length(turn_id) between 1 and 128),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  speaker     text not null check (speaker in ('user', 'assistant')),
  text        text not null check (char_length(text) between 1 and 20000),
  spoken_at   timestamptz not null,
  created_at  timestamptz not null default now(),
  primary key (notebook_id, turn_id)
);

create index conversation_turns_notebook_spoken_idx
  on public.conversation_turns (notebook_id, spoken_at);

alter table public.conversation_turns enable row level security;

create policy "owner select" on public.conversation_turns
  for select using (auth.uid() = user_id);
-- Only into the caller's own notebooks.
create policy "owner insert" on public.conversation_turns
  for insert with check (
    auth.uid() = user_id
    and exists (
      select 1 from public.notebooks n
      where n.id = notebook_id and n.user_id = auth.uid()
    )
  );
create policy "owner delete" on public.conversation_turns
  for delete using (auth.uid() = user_id);

revoke all on public.conversation_turns from anon;
revoke update on public.conversation_turns from authenticated;
