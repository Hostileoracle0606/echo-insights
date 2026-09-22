-- Lumen — initial auth + vault schema
-- See docs/superpowers/specs/2026-05-18-supabase-auth-and-vault-design.md §5

-- ────────────────────────────────────────────────────────────
-- profiles
-- ────────────────────────────────────────────────────────────
create table public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "owner select" on public.profiles
  for select using (auth.uid() = user_id);
create policy "owner insert" on public.profiles
  for insert with check (auth.uid() = user_id);
create policy "owner update" on public.profiles
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner delete" on public.profiles
  for delete using (auth.uid() = user_id);

-- Auto-insert a profile row when an auth.users row is created.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id, display_name)
  values (new.id, new.raw_user_meta_data->>'display_name');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ────────────────────────────────────────────────────────────
-- notebooks
-- ────────────────────────────────────────────────────────────
create table public.notebooks (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  title            text not null,
  title_source     text not null default 'auto' check (title_source in ('ai','user','auto')),
  started_at       timestamptz not null,
  ended_at         timestamptz,
  duration_seconds integer,
  entity_count     integer not null default 0,
  summary          text,
  archived_at      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index notebooks_user_started_idx on public.notebooks (user_id, started_at desc);

alter table public.notebooks enable row level security;

create policy "owner select" on public.notebooks
  for select using (auth.uid() = user_id);
create policy "owner insert" on public.notebooks
  for insert with check (auth.uid() = user_id);
create policy "owner update" on public.notebooks
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner delete" on public.notebooks
  for delete using (auth.uid() = user_id);

-- ────────────────────────────────────────────────────────────
-- journal_entries
-- ────────────────────────────────────────────────────────────
create table public.journal_entries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  notebook_id uuid not null references public.notebooks(id) on delete cascade,
  text        text not null,
  created_at  timestamptz not null
);

create index journal_entries_notebook_idx on public.journal_entries (notebook_id, created_at);

alter table public.journal_entries enable row level security;

create policy "owner select" on public.journal_entries
  for select using (auth.uid() = user_id);
create policy "owner insert" on public.journal_entries
  for insert with check (auth.uid() = user_id);
create policy "owner update" on public.journal_entries
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner delete" on public.journal_entries
  for delete using (auth.uid() = user_id);

-- ────────────────────────────────────────────────────────────
-- entities — composite PK (notebook_id, id) keeps the entity
-- slug stable within a notebook while letting the same slug
-- appear in multiple notebooks (the master-graph merge in
-- Plan 4 is visualize-only; storage stays notebook-scoped).
-- ────────────────────────────────────────────────────────────
create table public.entities (
  id          text not null,
  user_id     uuid not null references auth.users(id) on delete cascade,
  notebook_id uuid not null references public.notebooks(id) on delete cascade,
  name        text not null,
  type        text not null,
  description text,
  metadata    jsonb not null default '{}'::jsonb,
  mentions    integer not null default 1,
  first_seen  timestamptz not null,
  last_seen   timestamptz not null,
  questions   text[],
  primary key (notebook_id, id)
);

create index entities_user_name_idx on public.entities (user_id, name);

alter table public.entities enable row level security;

create policy "owner select" on public.entities
  for select using (auth.uid() = user_id);
create policy "owner insert" on public.entities
  for insert with check (auth.uid() = user_id);
create policy "owner update" on public.entities
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner delete" on public.entities
  for delete using (auth.uid() = user_id);

-- ────────────────────────────────────────────────────────────
-- relations — same composite-PK rationale
-- ────────────────────────────────────────────────────────────
create table public.relations (
  id            text not null,
  user_id       uuid not null references auth.users(id) on delete cascade,
  notebook_id   uuid not null references public.notebooks(id) on delete cascade,
  source_id     text not null,
  target_id     text not null,
  label         text not null,
  metadata      jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  superseded_at timestamptz,
  primary key (notebook_id, id)
);

create index relations_active_idx on public.relations (notebook_id)
  where superseded_at is null;

alter table public.relations enable row level security;

create policy "owner select" on public.relations
  for select using (auth.uid() = user_id);
create policy "owner insert" on public.relations
  for insert with check (auth.uid() = user_id);
create policy "owner update" on public.relations
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner delete" on public.relations
  for delete using (auth.uid() = user_id);

-- ────────────────────────────────────────────────────────────
-- follow_ups
-- ────────────────────────────────────────────────────────────
create table public.follow_ups (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  notebook_id       uuid not null references public.notebooks(id) on delete cascade,
  question          text not null,
  reason            text not null default '',
  target_entity_ids text[] not null default '{}'::text[],
  answered          boolean not null default false,
  created_at        timestamptz not null default now()
);

alter table public.follow_ups enable row level security;

create policy "owner select" on public.follow_ups
  for select using (auth.uid() = user_id);
create policy "owner insert" on public.follow_ups
  for insert with check (auth.uid() = user_id);
create policy "owner update" on public.follow_ups
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner delete" on public.follow_ups
  for delete using (auth.uid() = user_id);

-- ────────────────────────────────────────────────────────────
-- asked_questions
-- ────────────────────────────────────────────────────────────
create table public.asked_questions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  notebook_id       uuid not null references public.notebooks(id) on delete cascade,
  question          text not null,
  target_entity_ids text[] not null default '{}'::text[],
  asked_at          timestamptz not null default now()
);

create index asked_questions_recent_idx on public.asked_questions (notebook_id, asked_at desc);

alter table public.asked_questions enable row level security;

create policy "owner select" on public.asked_questions
  for select using (auth.uid() = user_id);
create policy "owner insert" on public.asked_questions
  for insert with check (auth.uid() = user_id);
create policy "owner update" on public.asked_questions
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner delete" on public.asked_questions
  for delete using (auth.uid() = user_id);
