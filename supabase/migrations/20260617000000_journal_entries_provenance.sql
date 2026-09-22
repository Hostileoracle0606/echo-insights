-- Durable provenance for GraphRAG retrieval: persist which entities/relations
-- each journal entry produced, so grounded source passages survive a reload.
alter table journal_entries
  add column if not exists entity_ids   text[] not null default '{}',
  add column if not exists relation_ids text[] not null default '{}';
