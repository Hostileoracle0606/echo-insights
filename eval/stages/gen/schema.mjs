// Schemas for generated benchmark data. Every world is synthetic and says so.
import { z } from 'zod';

export const FAMILY_NAMES = ['temporal_change', 'ambiguity', 'multi_hop', 'contradiction', 'paraphrase', 'distractor', 'unanswerable'];

const EntitySchema = z.object({
  id: z.string().regex(/^[a-z0-9-]+$/),
  name: z.string().min(1),
  nameParts: z.array(z.string().min(1)).min(1),
  aliases: z.array(z.string()),
  type: z.enum(['person', 'place', 'organization', 'project', 'event']),
  attributes: z.record(z.string(), z.string()),
});

const FactSchema = z.object({
  id: z.string(),
  session: z.number().int().min(1),
  kind: z.enum(['introduce', 'attribute', 'relation']),
  subject: z.string(),
  predicate: z.string(),
  object: z.string().optional(),
  value: z.string().optional(),
  statement: z.string().min(1),
  names: z.array(z.string()).min(1),
  supersedes: z.string().optional(),
});

const ActionSchema = z.object({ kind: z.enum(['remove', 'forget']), entityId: z.string(), name: z.string() });

const RelationSchema = z.object({
  source: z.string(),
  label: z.string(),
  target: z.string(),
  supersededInSession: z.number().int().nullable(),
});

const QuerySchema = z.object({
  id: z.string(),
  family: z.enum(FAMILY_NAMES),
  template: z.string(),
  intent: z.string().min(1),
  gold: z.array(z.object({ entityId: z.string(), relevance: z.union([z.literal(1), z.literal(2)]) })),
  answer: z.string(),
  answerable: z.boolean(),
  distractors: z.array(z.string()),
  avoidTerms: z.array(z.string()),
});

export const WorldSchema = z.object({
  id: z.string(),
  split: z.enum(['train', 'val', 'test']),
  synthetic: z.literal(true),
  seed: z.number().int(),
  families: z.array(z.enum(FAMILY_NAMES)).min(1),
  sessions: z.array(z.object({ facts: z.array(FactSchema), actions: z.array(ActionSchema) })).min(3),
  finalGraph: z.object({
    entities: z.array(EntitySchema).min(1),
    relations: z.array(RelationSchema),
    removed: z.array(z.string()),
  }),
  queries: z.array(QuerySchema).min(1),
}).strict();

export { QuerySchema, EntitySchema };
