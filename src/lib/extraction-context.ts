/**
 * Token-budgeted extraction context compiler.
 *
 * One deterministic function turns "a finalized transcript plus the notebook
 * graph" into the exact prompt context the extractor receives, bounded by a
 * measured token budget rather than by fixed item counts.
 *
 * Why a budget and not "top 20 entities": a count-bounded prompt is unbounded
 * in tokens (a handful of long descriptions can blow past any ceiling) *and*
 * systematically blind (a rarely-mentioned but highly relevant older entity
 * can never make the cut). Counts survive only as safety limits.
 *
 * Selection order, highest priority first:
 *   1. the new utterance (reserved — never dropped)
 *   2. exact normalized-name matches from the utterance
 *   3. semantically/lexically retrieved entities, in relevance order
 *   4. active relations among the kept entities, carrying their durable ids
 *   5. the open question this utterance answers
 *   6. as many recent finalized turns as still fit
 *
 * The new utterance is the only source of new facts. Everything else is
 * grounding material for identity resolution, pronouns, deduplication and
 * contradiction handling.
 */

import {
  buildUserMessage,
  MAX_PROMPT_ENTITIES,
  MAX_PROMPT_RELATIONS,
  MAX_PROMPT_TURNS,
  type ClientContext,
  type ConversationTurn,
  type GraphEntity,
  type GraphRelation,
} from "@/lib/extract-graph";
import { normalizeName } from "@/lib/graphloop/noise";
import type { RetrievalResult } from "@/lib/graphloop/types";
import type { Entity, FollowUp, JournalState } from "@/lib/journal-types";

/**
 * Deterministic token estimator, calibrated for SentencePiece-style vocabularies
 * (Gemini, Llama): roughly one token per four characters of word body, never
 * fewer than one token per whitespace-delimited word.
 *
 * It is intentionally injectable — swap in a real tokenizer via
 * `countTokens` and every bound in this module tightens automatically without
 * any other change.
 */
export function estimateTokens(text: string): number {
  if (!text) return 0;
  let tokens = 0;
  for (const word of text.split(/\s+/)) {
    if (!word) continue;
    tokens += Math.max(1, Math.ceil(word.length / 4));
  }
  return tokens;
}

export interface CompileExtractionContextInput {
  /** The immutable finalized transcript. Also the semantic retrieval query. */
  transcript: string;
  state: JournalState;
  /** Result of the existing semantic/lexical retrieval pass over this notebook. */
  retrieval: RetrievalResult;
  /** The open follow-up this utterance answers, if any. */
  answeringFollowUp?: FollowUp;
  /** Finalized conversation turns only, oldest first. */
  recentTurns: ConversationTurn[];
  /** Hard bound, in model tokens, for the whole rendered prompt. */
  budget: number;
  countTokens?: (text: string) => number;
}

export interface CompiledExtractionContext {
  existingEntities: GraphEntity[];
  existingRelations: GraphRelation[];
  recentConversation: ConversationTurn[];
  /** Ready to hand straight to `extractGraph({ text, context })`. */
  clientContext: ClientContext;
  tokensUsed: number;
  budget: number;
  dropped: { entities: number; relations: number; turns: number };
}

/** Default prompt budget. Comfortably inside Gemini Flash's window, and cheap. */
export const DEFAULT_EXTRACTION_TOKEN_BUDGET = 1800;

function toGraphEntity(entity: Entity, relationCount: number): GraphEntity {
  return {
    name: entity.name,
    type: entity.type,
    description: entity.description,
    mentionCount: entity.mentions,
    relationCount,
    lastMentionedAt: entity.lastSeen,
  };
}

/** Entities whose normalized name literally appears in the utterance. */
function exactNameMatches(state: JournalState, transcript: string): Set<string> {
  const normalizedQuery = normalizeName(transcript);
  const matches = new Set<string>();
  for (const entity of Object.values(state.entities)) {
    const normalized = normalizeName(entity.name);
    if (normalized.length >= 2 && normalizedQuery.includes(normalized)) matches.add(entity.id);
  }
  return matches;
}

export function compileExtractionContext(
  input: CompileExtractionContextInput,
): CompiledExtractionContext {
  const count = input.countTokens ?? estimateTokens;
  const { state, transcript, budget } = input;

  const render = (
    entities: GraphEntity[],
    relations: GraphRelation[],
    turns: ConversationTurn[],
    withFollowUp: boolean,
  ): string =>
    buildUserMessage({
      text: transcript,
      context: {
        existingEntities: entities,
        existingRelations: relations,
        recentConversation: turns,
        answeringFollowUp: withFollowUp ? followUpContext : undefined,
      },
    });

  const entityNamesById = new Map(
    Object.values(state.entities).map((entity) => [entity.id, entity.name]),
  );
  const followUpContext = input.answeringFollowUp
    ? {
        question: input.answeringFollowUp.question,
        reason: input.answeringFollowUp.reason,
        targetEntityNames: input.answeringFollowUp.targetEntityIds
          .map((id) => entityNamesById.get(id))
          .filter((name): name is string => Boolean(name)),
      }
    : undefined;

  // ---- candidate ordering ----
  const exact = exactNameMatches(state, transcript);
  const candidateIds = [
    // Exact matches first: they are the identity anchors that stop the model
    // from minting a duplicate node for something already in the graph.
    ...[...exact].filter((id) => state.entities[id]),
    ...input.retrieval.entities.map((e) => e.id).filter((id) => !exact.has(id)),
  ];

  const relationCounts = new Map<string, number>();
  for (const relation of Object.values(state.relations)) {
    if (relation.supersededAt) continue;
    relationCounts.set(relation.source, (relationCounts.get(relation.source) ?? 0) + 1);
    relationCounts.set(relation.target, (relationCounts.get(relation.target) ?? 0) + 1);
  }

  // ---- greedy packing under the measured budget ----
  const keptIds: string[] = [];
  let entities: GraphEntity[] = [];
  let relations: GraphRelation[] = [];
  let turns: ConversationTurn[] = [];
  let withFollowUp = false;

  const fits = (e: GraphEntity[], r: GraphRelation[], t: ConversationTurn[], f: boolean): boolean =>
    count(render(e, r, t, f)) <= budget;

  // The utterance alone may already exceed the budget. That is allowed: it is
  // the only source of new facts, so it is never trimmed — but nothing else
  // is then added on top of it.
  const baseFits = fits([], [], [], false);

  if (baseFits) {
    for (const id of candidateIds) {
      if (entities.length >= MAX_PROMPT_ENTITIES) break;
      const entity = state.entities[id];
      if (!entity) continue;
      const next = [...entities, toGraphEntity(entity, relationCounts.get(id) ?? 0)];
      if (!fits(next, relations, turns, withFollowUp)) break;
      entities = next;
      keptIds.push(id);
    }

    // Relations carry their durable ids so a contradiction can supersede the
    // right edge rather than a re-derived guess at it.
    const kept = new Set(keptIds);
    const activeRelations = Object.values(state.relations)
      .filter((r) => !r.supersededAt && kept.has(r.source) && kept.has(r.target))
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
    for (const relation of activeRelations) {
      if (relations.length >= MAX_PROMPT_RELATIONS) break;
      const next = [
        ...relations,
        {
          id: relation.id,
          source: entityNamesById.get(relation.source) ?? relation.source,
          target: entityNamesById.get(relation.target) ?? relation.target,
          label: relation.label,
          metadata: relation.metadata,
        },
      ];
      if (!fits(entities, next, turns, withFollowUp)) break;
      relations = next;
    }

    if (followUpContext && fits(entities, relations, turns, true)) withFollowUp = true;

    // Most recent turns first — they carry the pronouns being resolved.
    const ordered = [...input.recentTurns].reverse();
    for (const turn of ordered) {
      if (turns.length >= MAX_PROMPT_TURNS) break;
      const next = [turn, ...turns];
      if (!fits(entities, relations, next, withFollowUp)) break;
      turns = next;
    }
  }

  const clientContext: ClientContext = {
    existingEntities: entities,
    existingRelations: relations,
    recentConversation: turns,
    answeringFollowUp: withFollowUp ? followUpContext : undefined,
  };

  return {
    existingEntities: entities,
    existingRelations: relations,
    recentConversation: turns,
    clientContext,
    tokensUsed: count(render(entities, relations, turns, withFollowUp)),
    budget,
    dropped: {
      entities: candidateIds.length - entities.length,
      relations:
        Object.values(state.relations).filter((r) => !r.supersededAt).length - relations.length,
      turns: input.recentTurns.length - turns.length,
    },
  };
}
