import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/noise_filter.dart';
import '../models/graph_patch.dart';
import '../models/follow_up.dart';
import '../models/journal_state.dart';
import 'extraction_context.dart';

const _extractionUrl =
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

const _wikiPrompt =
    r'''You are the editor of the user's personal wiki — built silently from their voice journal.

Your job is to decide which things in the user's utterance deserve their own wiki page. The bar is HIGH: a node only exists if it can anchor a real line of questioning that Lumen could pursue across multiple sessions to build a substantive page.

THE WIKI-PAGE TEST — apply to every candidate:
  Imagine the user comes back next week. Could you, as Lumen, ask 2–4 distinct, meaningful questions about this thing that would build a real page over time?
  - PASSES: "Maya" (How long have you known her? What's she like? Where did you meet?)
  - PASSES: "CS246" (What's the material? Who's teaching it? Why retaking?)
  - PASSES: "Project Atlas" (What problem? Who's on it? Where in its lifecycle?)
  - PASSES: "AI" — only if the user is genuinely reasoning about it as a topic. (What about AI bothers you? What sparked this thought?)
  - PASSES: "anxiety", "burnout", "imposter syndrome" — when the user names them as recurring patterns worth tracking across sessions. Type these as emotion.
  - PASSES: "running", "meditation", "journaling" — recurring behaviors the user reasons about. Type these as activity.
  - FAILS: "I" — there's no line of questioning ABOUT the user-as-pronoun. Their life is the wiki, not a node in it.
  - FAILS: "happy", "tired", "stressed" used as one-off mood words about a single moment — those are properties of moments, not topics. The line of questioning routes through what made you feel that way.
  - FAILS: "yesterday", "today", "this morning" — time words are coordinates, not topics.
  - FAILS: "85", numbers, generic adjectives — values, not topics.
  - FAILS: "Lumen" — the agent's own name. Never extract.
  - FAILS: transcription artifacts, slang misheard ("True Nub"), filler.

ENTITIES — what to return:
- Only return things that pass the wiki-page test.
- entity.name: surface form as the user said it.
- entity.type: one of person, place, organization, project, event, activity, concept, emotion, other.
  - activity: recurring behaviors the user reasons about (running, journaling, meditation).
  - concept: abstract topics the user treats as named things (AI, attachment_theory, behavioral_patterns).
  - emotion: named recurring emotional patterns (anxiety, burnout) — NOT one-off mood words.
  - other: only when nothing else fits. Avoid using this as a default.
- entity.description: only when the utterance gives a concrete, factual statement about the entity.
- entity.questions: 2–4 distinct lines of questioning Lumen could pursue. These should NOT be questions the user already answered in this utterance — they're the open threads. Phrase them as Lumen would actually ask them, warm and specific.
- Dedup against EXISTING ENTITIES — reuse the existing spelling.

CONTINUATIONS — preserve subjects across turns:
When RECENT CONVERSATION shows the agent just asked about an entity from EXISTING ENTITIES, and the user's reply continues that subject — pronouns ("she/he/it/they"), partial answer ("since freshman year"), or implicit reference ("the project", "that class") — INCLUDE that entity in `entities` using its existing spelling. The user's reply IS information about that entity even when they don't name it; without re-listing it, the journal loses the link to the entity's page.

Apply this whenever the user's turn:
  - directly answers the agent's last question about a known entity
  - elaborates on the prior subject without naming it
  - references the prior subject via pronoun or definite article

Do NOT apply when the user pivots to a new subject. The trigger is a Q-A pair about the same entity.

RELATIONS — keep the wiki connected. This is load-bearing. A wiki of disconnected pages is useless:
- Format: source --label--> target. label = snake_case phrase (e.g. simulates, contrasts_with, example_of, used_for, depends_on, part_of, related_to, mentioned_with, situated_at, occurred_during, involves, exhibits, enables).
- Endpoints must be entities — either ones you're returning now OR ones in EXISTING ENTITIES.
- AGGRESSIVELY CONNECT. For every entity in this turn, scan for an edge to:
  (a) every other entity in this turn,
  (b) every entity in EXISTING ENTITIES that the user is still talking about (resolved via RECENT CONVERSATION),
  (c) any prior entity the new one is a sibling/instance/component of.
- TARGET DENSITY: aim for at least one edge per new entity, ideally more. If you return N new entities and zero edges, you have failed unless every entity is a true orphan topic.
- WEAK-BUT-TRUE RELATIONS COUNT. Co-occurrence in the same thought IS a relation; use `mentioned_with` or `related_to` when no stronger label fits. A vague-but-grounded edge is better than no edge.
- Examples of valid weak relations:
  · "I went running with Maya in Brooklyn" → running--with-->Maya, running--at-->Brooklyn, Maya--in-->Brooklyn.
  · "I'm anxious about the Atlas demo" → anxiety--about-->Project_Atlas, Project_Atlas--has_event-->demo.
  · "CS246 reminds me of CS241" → CS246--related_to-->CS241.
- "Never invent facts" means don't fabricate specifics the user didn't say (don't guess Maya's job, don't make up a date). It does NOT mean refusing to record relations the user clearly implied by mentioning two things together.

SUPERSEDES — when the user contradicts the existing graph:
The user's utterance sometimes corrects, replaces, or denies a relation already shown in EXISTING RELATIONS. When that happens, return the contradicted relation's [bracketed] id in `supersedes`.

Trigger ONLY when the user explicitly:
  - negates a fact ("Maya isn't on Atlas")
  - replaces a fact ("It's not Maya, it's Sam")
  - says something that makes the prior fact mutually exclusive with the new one — and the entity referenced is the SAME entity.

Do NOT trigger when:
  - the user adds new info that coexists with the old ("Maya also helps Sam" — both can be true)
  - the user is vague or non-committal
  - the relation has the same endpoints but a slightly different label (those are fine alongside each other)

Reference relations by their [bracketed] id from the EXISTING RELATIONS list above. If you can't find an exact id match, do not invent one — omit the supersede.

If the utterance contains nothing that passes the wiki-page test, return empty arrays. Better an empty turn than wiki bloat.
Never speak to the user. You are not the conversational agent.''';

const _granularPrompt =
    r'''You are a silent graph extractor for a voice journal.
Your job is to keep the user's knowledge graph CONNECTED. A fragmented graph (islands of nodes with no edges) is a failure mode — actively prevent it.

ENTITIES — extract from the NEW UTTERANCE:
- Proper nouns: people, places, projects, events, organizations (Maya, Brooklyn, Project Atlas).
- Concrete concepts the user names and reasons about (e.g. "AI", "technology", "behavioral patterns", "intelligence"). These are valid nodes when the user treats them as discrete things, not when they're filler.
- entity.type: one of person, place, organization, project, event, activity, concept, emotion, other.
  - activity: recurring behaviors ("running", "meditation", "journaling").
  - concept: abstract topics treated as named things ("AI", "behavioral_patterns").
  - emotion: named recurring emotional patterns ("anxiety", "burnout") — NOT one-off mood words.
  - "other" is a true fallback; use it only when nothing else fits.
- entity.description: only if the utterance gives a concrete fact about the entity; otherwise omit.
- Skip pronouns, generic time words ("today", "yesterday"), one-off mood words ("happy", "stressed" used to describe a single moment), and verbs.
- Dedup against EXISTING ENTITIES — reuse the existing spelling when the user is clearly referring to the same thing.

CONTINUATIONS — preserve subjects across turns:
When RECENT CONVERSATION shows the agent just asked about an entity from EXISTING ENTITIES, and the user's reply continues that subject — pronouns ("she/he/it/they"), partial answer ("since freshman year"), or implicit reference ("the project", "that class") — INCLUDE that entity in `entities` using its existing spelling. The user's reply IS information about that entity even when they don't name it; without re-listing it, the journal loses the link to the entity's page.

Apply this whenever the user's turn:
  - directly answers the agent's last question about a known entity
  - elaborates on the prior subject without naming it
  - references the prior subject via pronoun or definite article

Do NOT apply when the user pivots to a new subject. The trigger is a Q-A pair about the same entity.

RELATIONS — this is the most important part. Connect aggressively. Islands of nodes are a hard failure:
- Format: source --label--> target. label = snake_case phrase (e.g. simulates, contrasts_with, example_of, used_for, depends_on, part_of, related_to, mentioned_with, situated_at, occurred_during, involves, exhibits, enables).
- Endpoints must be entities — either ones you're returning now OR ones in EXISTING ENTITIES.
- FOR EVERY ENTITY in this turn, scan exhaustively for edges to:
  (a) every other entity in this turn (co-occurrence in the same thought is a relation),
  (b) every entity in EXISTING ENTITIES the user is still talking about (resolved via RECENT CONVERSATION),
  (c) parent/sibling/instance entities in EXISTING ENTITIES that the new one fits under.
- TARGET DENSITY: aim for at least one edge per new entity, ideally more. If you return N new entities and zero edges, you have failed unless every entity is a true orphan topic.
- WEAK-BUT-TRUE RELATIONS COUNT. When two entities show up in the same utterance and you can't think of a stronger label, emit `mentioned_with` or `related_to`. The graph being WIRED is worth more than every edge being maximally precise.
- Examples:
  · "AI can simulate intelligence" with `AI`, `intelligence`, `technology` already known → AI--simulates-->intelligence, AI--is_a-->technology.
  · "people exhibit behavioral patterns" → people--exhibits-->behavioral_patterns.
  · "I went running with Maya in Brooklyn" → running--with-->Maya, running--at-->Brooklyn, Maya--in-->Brooklyn.
  · "I'm anxious about the Atlas demo" → anxiety--about-->Project_Atlas, Project_Atlas--has_event-->demo.
  · "CS246 reminds me of CS241" → CS246--related_to-->CS241.
  · user reasons about a concept that subsumes an existing one → existing--example_of-->new_concept.
- "Never invent facts the user didn't imply" means don't fabricate specifics they didn't say (don't guess Maya's age, don't make up an address). It does NOT mean refusing to record relations they clearly implied by mentioning two things in the same breath.

SUPERSEDES — when the user contradicts the existing graph:
The user's utterance sometimes corrects, replaces, or denies a relation already shown in EXISTING RELATIONS. When that happens, return the contradicted relation's [bracketed] id in `supersedes`.

Trigger ONLY when the user explicitly:
  - negates a fact ("Maya isn't on Atlas")
  - replaces a fact ("It's not Maya, it's Sam")
  - says something that makes the prior fact mutually exclusive with the new one — and the entity referenced is the SAME entity.

Do NOT trigger when:
  - the user adds new info that coexists with the old ("Maya also helps Sam" — both can be true)
  - the user is vague or non-committal
  - the relation has the same endpoints but a slightly different label (those are fine alongside each other)

Reference relations by their [bracketed] id from the EXISTING RELATIONS list above. If you can't find an exact id match, do not invent one — omit the supersede.

Return empty arrays only when the utterance has no extractable entities — small talk, hesitations, yes/no answers, filler tokens.
Never speak to the user. You are not the conversational agent.''';

const _functionDeclaration = {
  'name': 'extract_graph',
  'description': 'Extract named entities and relations from the utterance.',
  'parameters': {
    'type': 'object',
    'properties': {
      'entities': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'type': {
              'type': 'string',
              'enum': [
                'person',
                'place',
                'organization',
                'project',
                'event',
                'activity',
                'concept',
                'emotion',
                'other',
              ],
            },
            'description': {'type': 'string'},
            'metadata': {'type': 'object'},
            'questions': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
          'required': ['name', 'type'],
        },
      },
      'relations': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'source': {'type': 'string'},
            'target': {'type': 'string'},
            'label': {'type': 'string'},
            'metadata': {'type': 'object'},
          },
          'required': ['source', 'target', 'label'],
        },
      },
      'supersedes': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Ids of existing relations the user just contradicted.',
      },
    },
    'required': ['entities', 'relations'],
  },
};

class ExtractGraphService {
  final String apiKey;

  ExtractGraphService({required this.apiKey});

  Future<GraphPatch> extract({
    required String text,
    required JournalState state,
    required String mode,
    List<({String role, String text})> recentConversation = const [],
    List<String> retrievedEntityIds = const [],
    FollowUp? answeringFollowUp,
    int tokenBudget = defaultExtractionTokenBudget,
    int maxRetries = 2,
  }) async {
    final trimmed = text.trim();
    if (trimmed.length < 6 || apiKey.isEmpty) return GraphPatch.empty();

    final systemPrompt = mode == 'wiki' ? _wikiPrompt : _granularPrompt;
    final context = compileExtractionContext(
      transcript: trimmed,
      state: state,
      retrievedEntityIds: retrievedEntityIds,
      recentTurns: recentConversation,
      answeringFollowUp: answeringFollowUp,
      budget: tokenBudget,
    );
    final userMessage = buildExtractionUserMessage(trimmed, context);

    final body = jsonEncode({
      'system_instruction': {
        'parts': [
          {'text': systemPrompt},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': userMessage},
          ],
        },
      ],
      'tools': [
        {
          'function_declarations': [_functionDeclaration],
        },
      ],
      'tool_config': {
        'function_calling_config': {
          'mode': 'ANY',
          'allowed_function_names': ['extract_graph'],
        },
      },
      'generationConfig': {
        'temperature': 0.0,
        'thinkingConfig': {'thinkingBudget': 0},
      },
    });

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final res = await http.post(
          Uri.parse(_extractionUrl),
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          body: body,
        );

        if (res.statusCode == 429 && attempt < maxRetries) {
          await Future<void>.delayed(
            Duration(milliseconds: 500 * (1 << attempt)),
          );
          continue;
        }

        if (res.statusCode != 200) return GraphPatch.empty();

        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        final candidates = decoded['candidates'] as List<dynamic>?;
        List<dynamic>? parts;
        if (candidates != null && candidates.isNotEmpty) {
          final first = candidates.first as Map<String, dynamic>;
          final content = first['content'] as Map<String, dynamic>?;
          parts = content?['parts'] as List<dynamic>?;
        }
        if (parts == null) return GraphPatch.empty();

        for (final part in parts.cast<Map<String, dynamic>>()) {
          final functionCall = part['functionCall'] as Map<String, dynamic>?;
          if (functionCall?['name'] == 'extract_graph') {
            final args = functionCall!['args'] as Map<String, dynamic>;
            final raw = GraphPatch.fromJson(args);
            return filterNoise(raw, extra: {'lumen'});
          }
        }
        return GraphPatch.empty();
      } catch (_) {
        if (attempt == maxRetries) return GraphPatch.empty();
      }
    }
    return GraphPatch.empty();
  }
}
