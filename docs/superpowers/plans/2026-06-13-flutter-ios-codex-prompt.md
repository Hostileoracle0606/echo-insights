# Codex Agent Prompt — Lumen iOS (Flutter)

> **Usage:** paste this entire document as the system/task prompt for a Codex agent.
> The agent starts in a fresh Flutter workspace. No prior context is assumed.

---

## Mission

Build **Lumen** — a voice-first iOS journaling app that silently grows a live knowledge graph as the user speaks. The user talks; the app listens, extracts named entities and relations, and asks one warm follow-up question per turn. A force-directed graph pulses in the background, showing the user's world taking shape.

This is a **Flutter iOS app**. Target: iOS 16+, iPhone only for v1. Dart 3.4+, Flutter 3.22+.

---

## What the app does (user's perspective)

1. User opens the app → Supabase auth gate (email/password).
2. Authenticated → Journal screen. The app opens a session (a "notebook") in Supabase.
3. User taps the mic. Gemini Live opens a WebSocket. The agent greets them by pulling on a thread from their last session (or says "What's on your mind?" on first session).
4. User speaks. Audio streams to Gemini Live at 16kHz PCM. Gemini transcribes and responds with voice. All in real-time.
5. In parallel, every time the user completes a sentence (`.!?` punctuation or 700ms silence), that transcript fragment is sent to Gemini 2.5 Flash (REST) to extract named entities and relations — a `GraphPatch`. The patch is merged into the running `JournalState`. The Supabase tables are updated.
6. Before each reply, Gemini Live calls a registered tool `get_graph_summary` to read the current graph state and decide its next question. The user never sees this.
7. The knowledge graph renders as an animated force-directed canvas in the background. Nodes are entity types (person, place, project…), edges are relations.
8. User taps mic again to end. Session ends, `ended_at` is stamped on the notebook.

---

## Tech stack decisions

| Concern                  | Choice                     | Package                                                |
| ------------------------ | -------------------------- | ------------------------------------------------------ |
| State management         | Riverpod                   | `flutter_riverpod`, `riverpod_annotation`              |
| Navigation               | GoRouter                   | `go_router`                                            |
| Gemini Live (voice)      | WebSocket                  | `web_socket_channel`                                   |
| Gemini REST (extraction) | HTTP                       | `http`                                                 |
| Microphone capture       | Record                     | `record`                                               |
| PCM playback             | just_audio + custom source | `just_audio`                                           |
| Supabase                 | supabase_flutter           | `supabase_flutter`                                     |
| JSON serialization       | json_serializable          | `json_serializable`, `json_annotation`, `build_runner` |
| Graph rendering          | CustomPainter (no package) | —                                                      |
| Env / secrets            | flutter_dotenv             | `flutter_dotenv`                                       |

Do **not** add packages beyond this list without a clear reason. No GetX, no Provider, no BLoC.

---

## pubspec.yaml

```yaml
name: lumen
description: Voice journaling that builds a live knowledge graph.
version: 1.0.0+1

environment:
  sdk: ">=3.4.0 <4.0.0"
  flutter: ">=3.22.0"

dependencies:
  flutter:
    sdk: flutter

  # State
  flutter_riverpod: ^2.5.1
  riverpod_annotation: ^2.3.5

  # Navigation
  go_router: ^14.2.0

  # Networking
  web_socket_channel: ^3.0.1
  http: ^1.2.2

  # Audio
  record: ^5.1.2
  just_audio: ^0.9.40

  # Supabase
  supabase_flutter: ^2.5.3

  # Serialization
  json_annotation: ^4.9.0

  # Env
  flutter_dotenv: ^5.2.1

  # Utilities
  uuid: ^4.4.2
  path_provider: ^2.1.4

dev_dependencies:
  flutter_test:
    sdk: flutter
  build_runner: ^2.4.11
  json_serializable: ^6.8.0
  riverpod_generator: ^2.4.0
  flutter_lints: ^4.0.0
```

---

## File manifest

Create every file below. Paths are relative to the Flutter project root.

```
lib/
├── main.dart
├── app.dart
├── env.dart
│
├── models/
│   ├── entity.dart
│   ├── relation.dart
│   ├── journal_entry.dart
│   ├── follow_up.dart
│   ├── asked_question.dart
│   ├── notebook.dart
│   ├── journal_state.dart
│   ├── graph_patch.dart
│   └── agenda.dart
│
├── logic/
│   ├── slugify.dart
│   ├── noise_filter.dart
│   ├── merge.dart
│   ├── agenda.dart
│   └── conversation_policy.dart
│
├── services/
│   ├── gemini_live_client.dart
│   ├── extract_graph_service.dart
│   └── supabase_service.dart
│
├── audio/
│   ├── pcm_capture.dart
│   └── pcm_player.dart
│
├── providers/
│   ├── auth_provider.dart
│   ├── supabase_provider.dart
│   ├── journal_provider.dart
│   └── session_provider.dart
│
├── screens/
│   ├── auth/
│   │   ├── login_screen.dart
│   │   └── signup_screen.dart
│   └── journal/
│       ├── journal_screen.dart
│       ├── graph_canvas.dart
│       ├── transcript_overlay.dart
│       └── mic_button.dart
│
└── widgets/
    ├── node_glyph.dart
    └── graph_legend.dart

assets/
└── .env          (not committed — contains GEMINI_API_KEY and SUPABASE credentials)

test/
├── merge_test.dart
├── slugify_test.dart
├── noise_filter_test.dart
└── agenda_test.dart
```

---

## Environment variables (`.env`)

```
GEMINI_API_KEY=<user fills in>
SUPABASE_URL=<user fills in>
SUPABASE_ANON_KEY=<user fills in>
```

Load in `main.dart` via `flutter_dotenv` before any other initialization.

---

## Data models

### `lib/models/entity.dart`

```dart
import 'package:json_annotation/json_annotation.dart';
part 'entity.g.dart';

enum EntityType {
  person, place, organization, project, event, activity, concept, emotion, other;
}

@JsonSerializable()
class Entity {
  final String id;        // slugified name
  final String name;
  final EntityType type;
  final String? description;
  final Map<String, dynamic> metadata;
  final int mentions;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final List<String>? questions; // wiki-mode backlog

  const Entity({
    required this.id,
    required this.name,
    required this.type,
    this.description,
    required this.metadata,
    required this.mentions,
    required this.firstSeen,
    required this.lastSeen,
    this.questions,
  });

  factory Entity.fromJson(Map<String, dynamic> json) => _$EntityFromJson(json);
  Map<String, dynamic> toJson() => _$EntityToJson(this);

  Entity copyWith({
    String? description,
    Map<String, dynamic>? metadata,
    int? mentions,
    DateTime? lastSeen,
    EntityType? type,
    List<String>? questions,
  }) => Entity(
    id: id,
    name: name,
    type: type ?? this.type,
    description: description ?? this.description,
    metadata: metadata ?? this.metadata,
    mentions: mentions ?? this.mentions,
    firstSeen: firstSeen,
    lastSeen: lastSeen ?? this.lastSeen,
    questions: questions ?? this.questions,
  );
}
```

### `lib/models/relation.dart`

```dart
import 'package:json_annotation/json_annotation.dart';
part 'relation.g.dart';

@JsonSerializable()
class Relation {
  final String id;            // "${source}__${label}__${target}"
  final String source;        // entity id
  final String target;        // entity id
  final String label;         // snake_case verb phrase
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
  final DateTime? supersededAt;  // soft-delete timestamp

  const Relation({
    required this.id,
    required this.source,
    required this.target,
    required this.label,
    required this.metadata,
    required this.createdAt,
    this.supersededAt,
  });

  bool get isActive => supersededAt == null;

  factory Relation.fromJson(Map<String, dynamic> json) => _$RelationFromJson(json);
  Map<String, dynamic> toJson() => _$RelationToJson(this);
}
```

### `lib/models/journal_entry.dart`

```dart
import 'package:json_annotation/json_annotation.dart';
part 'journal_entry.g.dart';

@JsonSerializable()
class JournalEntry {
  final String id;
  final String text;
  final DateTime createdAt;
  final List<String> entityIds;
  final List<String> relationIds;

  const JournalEntry({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.entityIds,
    required this.relationIds,
  });

  factory JournalEntry.fromJson(Map<String, dynamic> json) => _$JournalEntryFromJson(json);
  Map<String, dynamic> toJson() => _$JournalEntryToJson(this);
}
```

### `lib/models/follow_up.dart`

```dart
import 'package:json_annotation/json_annotation.dart';
part 'follow_up.g.dart';

@JsonSerializable()
class FollowUp {
  final String id;
  final String question;
  final String reason;
  final List<String> targetEntityIds;
  final DateTime createdAt;
  final bool answered;

  const FollowUp({
    required this.id,
    required this.question,
    required this.reason,
    required this.targetEntityIds,
    required this.createdAt,
    required this.answered,
  });

  factory FollowUp.fromJson(Map<String, dynamic> json) => _$FollowUpFromJson(json);
  Map<String, dynamic> toJson() => _$FollowUpToJson(this);
}
```

### `lib/models/notebook.dart`

```dart
import 'package:json_annotation/json_annotation.dart';
part 'notebook.g.dart';

@JsonSerializable()
class Notebook {
  final String id;
  final String userId;
  final String title;
  final String titleSource;  // "ai" | "user" | "auto"
  final DateTime startedAt;
  final DateTime? endedAt;
  final int entityCount;
  final String? summary;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Notebook({
    required this.id,
    required this.userId,
    required this.title,
    required this.titleSource,
    required this.startedAt,
    this.endedAt,
    required this.entityCount,
    this.summary,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Notebook.fromJson(Map<String, dynamic> json) => _$NotebookFromJson(json);
  Map<String, dynamic> toJson() => _$NotebookToJson(this);
}
```

### `lib/models/journal_state.dart`

```dart
import 'entity.dart';
import 'relation.dart';
import 'journal_entry.dart';
import 'follow_up.dart';

class JournalState {
  final List<JournalEntry> entries;       // newest-first
  final Map<String, Entity> entities;
  final Map<String, Relation> relations;
  final List<FollowUp> followUps;

  const JournalState({
    required this.entries,
    required this.entities,
    required this.relations,
    required this.followUps,
  });

  static JournalState empty() => const JournalState(
    entries: [],
    entities: {},
    relations: {},
    followUps: [],
  );

  JournalState copyWith({
    List<JournalEntry>? entries,
    Map<String, Entity>? entities,
    Map<String, Relation>? relations,
    List<FollowUp>? followUps,
  }) => JournalState(
    entries: entries ?? this.entries,
    entities: entities ?? this.entities,
    relations: relations ?? this.relations,
    followUps: followUps ?? this.followUps,
  );
}
```

### `lib/models/graph_patch.dart`

```dart
import 'entity.dart';

class EntityPatch {
  final String name;
  final EntityType type;
  final String? description;
  final Map<String, String>? metadata;
  final List<String>? questions;

  const EntityPatch({
    required this.name,
    required this.type,
    this.description,
    this.metadata,
    this.questions,
  });

  factory EntityPatch.fromJson(Map<String, dynamic> j) => EntityPatch(
    name: j['name'] as String,
    type: EntityType.values.firstWhere(
      (e) => e.name == j['type'],
      orElse: () => EntityType.other,
    ),
    description: j['description'] as String?,
    metadata: (j['metadata'] as Map<String, dynamic>?)?.cast<String, String>(),
    questions: (j['questions'] as List<dynamic>?)?.cast<String>(),
  );
}

class RelationPatch {
  final String source;
  final String target;
  final String label;
  final Map<String, String>? metadata;

  const RelationPatch({
    required this.source,
    required this.target,
    required this.label,
    this.metadata,
  });

  factory RelationPatch.fromJson(Map<String, dynamic> j) => RelationPatch(
    source: j['source'] as String,
    target: j['target'] as String,
    label: j['label'] as String,
    metadata: (j['metadata'] as Map<String, dynamic>?)?.cast<String, String>(),
  );
}

class GraphPatch {
  final List<EntityPatch> entities;
  final List<RelationPatch> relations;
  final List<String> supersedes;

  const GraphPatch({
    required this.entities,
    required this.relations,
    required this.supersedes,
  });

  static GraphPatch empty() =>
      const GraphPatch(entities: [], relations: [], supersedes: []);

  factory GraphPatch.fromJson(Map<String, dynamic> j) => GraphPatch(
    entities: (j['entities'] as List<dynamic>? ?? [])
        .map((e) => EntityPatch.fromJson(e as Map<String, dynamic>))
        .toList(),
    relations: (j['relations'] as List<dynamic>? ?? [])
        .map((r) => RelationPatch.fromJson(r as Map<String, dynamic>))
        .toList(),
    supersedes: (j['supersedes'] as List<dynamic>? ?? []).cast<String>(),
  );
}
```

### `lib/models/agenda.dart`

```dart
class UncertainRelation {
  final String source;
  final String label;
  final String target;
  final int score;
  const UncertainRelation({required this.source, required this.label, required this.target, required this.score});
}

class OpenQuestion {
  final String entity;
  final String question;
  const OpenQuestion({required this.entity, required this.question});
}

class Agenda {
  final List<String> thinEntities;
  final List<String> justMentioned;
  final List<UncertainRelation> uncertainRelations;
  final List<(String, String)> bridgeCandidates;
  final List<OpenQuestion> openQuestions;
  final int entityCount;
  final int relationCount;

  const Agenda({
    required this.thinEntities,
    required this.justMentioned,
    required this.uncertainRelations,
    required this.bridgeCandidates,
    required this.openQuestions,
    required this.entityCount,
    required this.relationCount,
  });
}
```

---

## Pure logic layer

### `lib/logic/slugify.dart`

```dart
String slugify(String name) {
  var s = name.toLowerCase();
  // NFKD normalization + diacritic strip (simplified for Dart)
  s = s.replaceAll(RegExp(r'[àáâãäå]'), 'a')
       .replaceAll(RegExp(r'[èéêë]'), 'e')
       .replaceAll(RegExp(r'[ìíîï]'), 'i')
       .replaceAll(RegExp(r'[òóôõö]'), 'o')
       .replaceAll(RegExp(r'[ùúûü]'), 'u')
       .replaceAll(RegExp(r'[ñ]'), 'n')
       .replaceAll(RegExp(r'[ç]'), 'c');
  s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  s = s.replaceAll(RegExp(r'^-|-$'), '');
  if (s.length > 60) s = s.substring(0, 60);
  if (s.isEmpty) return 'e-${DateTime.now().millisecondsSinceEpoch}';
  return s;
}

String relationId(String source, String label, String target) =>
    '${slugify(source)}__${label}__${slugify(target)}';
```

### `lib/logic/noise_filter.dart`

```dart
import '../models/graph_patch.dart';

const _defaultNoise = {
  'i', 'me', 'my', 'mine', 'you', 'your', 'yours', 'we', 'us', 'our',
  'they', 'them', 'their',
  'today', 'yesterday', 'tomorrow', 'morning', 'afternoon', 'evening',
  'night', 'now', 'later',
};

String normalizeName(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]+'), '').trim();

GraphPatch filterNoise(GraphPatch patch, {Set<String>? extra}) {
  final stop = {..._defaultNoise, ...(extra ?? {})};

  final kept = patch.entities.where((e) {
    final key = normalizeName(e.name);
    return key.isNotEmpty && key.length >= 2 && !stop.contains(key);
  }).toList();

  final keptKeys = kept.map((e) => normalizeName(e.name)).toSet();
  final droppedKeys = patch.entities
      .map((e) => normalizeName(e.name))
      .where((k) => !keptKeys.contains(k))
      .toSet();

  final relations = patch.relations
      .where((r) =>
          !droppedKeys.contains(normalizeName(r.source)) &&
          !droppedKeys.contains(normalizeName(r.target)))
      .toList();

  return GraphPatch(
    entities: kept,
    relations: relations,
    supersedes: patch.supersedes,
  );
}
```

### `lib/logic/merge.dart`

This is the core pure reducer. No side effects.

```dart
import '../models/entity.dart';
import '../models/graph_patch.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';
import 'slugify.dart';

const _maxQuestionsPerEntity = 8;

List<String>? _mergeQuestions(List<String>? existing, List<String>? incoming) {
  if ((existing == null || existing.isEmpty) && (incoming == null || incoming.isEmpty)) {
    return existing;
  }
  final seen = <String>{};
  final merged = <String>[];
  for (final q in [...(incoming ?? []), ...(existing ?? [])]) {
    final key = q.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]+'), '');
    if (key.isEmpty || seen.contains(key)) continue;
    seen.add(key);
    merged.add(q.trim());
    if (merged.length >= _maxQuestionsPerEntity) break;
  }
  return merged.isEmpty ? null : merged;
}

({JournalState next, String entryId}) merge(
  JournalState prev,
  String text,
  GraphPatch patch,
) {
  final now = DateTime.now().toUtc();
  final entities = Map<String, Entity>.from(prev.entities);
  final relations = Map<String, Relation>.from(prev.relations);
  final entryEntityIds = <String>[];
  final entryRelationIds = <String>[];
  final nameToId = <String, String>{};

  // Upsert entities
  for (final e in patch.entities) {
    if (e.name.isEmpty) continue;
    final id = slugify(e.name);
    nameToId[e.name.toLowerCase()] = id;
    final existing = entities[id];
    if (existing != null) {
      entities[id] = existing.copyWith(
        description: e.description?.isNotEmpty == true ? e.description : existing.description,
        metadata: {...existing.metadata, ...(e.metadata ?? {})},
        mentions: existing.mentions + 1,
        lastSeen: now,
        type: existing.type == EntityType.other ? e.type : existing.type,
        questions: _mergeQuestions(existing.questions, e.questions),
      );
    } else {
      entities[id] = Entity(
        id: id,
        name: e.name,
        type: e.type,
        description: e.description,
        metadata: e.metadata ?? {},
        mentions: 1,
        firstSeen: now,
        lastSeen: now,
        questions: _mergeQuestions(null, e.questions),
      );
    }
    entryEntityIds.add(id);
  }

  final explicitIds = nameToId.values.toSet();

  // Upsert relations — re-asserting a superseded relation clears supersededAt (self-heal)
  for (final r in patch.relations) {
    final src = nameToId[r.source.toLowerCase()] ?? slugify(r.source);
    final tgt = nameToId[r.target.toLowerCase()] ?? slugify(r.target);
    if (src.isEmpty || tgt.isEmpty || src == tgt) continue;
    final rid = '${src}__${r.label}__$tgt';

    final existing = relations[rid];
    if (existing == null) {
      relations[rid] = Relation(
        id: rid,
        source: src,
        target: tgt,
        label: r.label,
        metadata: r.metadata ?? {},
        createdAt: now,
      );
    } else {
      // Self-heal: spread without supersededAt
      relations[rid] = Relation(
        id: rid,
        source: existing.source,
        target: existing.target,
        label: existing.label,
        metadata: {...existing.metadata, ...(r.metadata ?? {})},
        createdAt: existing.createdAt,
        // supersededAt intentionally omitted — clears it
      );
    }
    entryRelationIds.add(rid);

    // Backfill: bump mention count on relation endpoints not explicitly in this patch
    for (final id in [src, tgt]) {
      if (explicitIds.contains(id) || !entities.containsKey(id)) continue;
      final e = entities[id]!;
      entities[id] = e.copyWith(mentions: e.mentions + 1, lastSeen: now);
      if (!entryEntityIds.contains(id)) entryEntityIds.add(id);
    }
  }

  // Apply supersedes (soft-delete)
  for (final id in patch.supersedes) {
    final r = relations[id];
    if (r == null || r.supersededAt != null) continue;
    relations[id] = Relation(
      id: r.id,
      source: r.source,
      target: r.target,
      label: r.label,
      metadata: r.metadata,
      createdAt: r.createdAt,
      supersededAt: now,
    );
  }

  final entryId = 'e-${now.millisecondsSinceEpoch}';
  final entry = JournalEntry(
    id: entryId,
    text: text,
    createdAt: now,
    entityIds: entryEntityIds.toSet().toList(),
    relationIds: entryRelationIds.toSet().toList(),
  );

  return (
    next: prev.copyWith(
      entries: [entry, ...prev.entries],
      entities: entities,
      relations: relations,
    ),
    entryId: entryId,
  );
}
```

### `lib/logic/agenda.dart`

```dart
import '../models/agenda.dart';
import '../models/entity.dart';
import '../models/journal_state.dart';

int _wordCount(String? s) =>
    s == null || s.isEmpty ? 0 : s.trim().split(RegExp(r'\s+')).length;

Agenda buildAgenda(JournalState state, {String? lastUserText}) {
  final entities = state.entities.values.toList();
  final activeRelations =
      state.relations.values.where((r) => r.isActive).toList();

  // Word coverage per entity
  final wordsByEntity = <String, int>{};
  for (final e in entities) {
    wordsByEntity[e.id] = _wordCount(e.description);
  }
  for (final entry in state.entries) {
    for (final eid in entry.entityIds) {
      wordsByEntity[eid] =
          (wordsByEntity[eid] ?? 0) + _wordCount(entry.text);
    }
  }

  final thinEntities = entities
      .where((e) => (wordsByEntity[e.id] ?? 0) < 30)
      .toList()
    ..sort((a, b) => b.mentions.compareTo(a.mentions));

  // justMentioned
  final probeText = (lastUserText ?? state.entries.firstOrNull?.text ?? '').toLowerCase();
  final justMentioned = entities
      .where((e) => probeText.contains(e.name.toLowerCase()))
      .map((e) => e.name)
      .toList();

  // uncertainRelations
  final mentionCountByRelation = <String, int>{};
  final firstEntryByEntity = <String, String>{};
  for (final entry in state.entries) {
    for (final rid in entry.relationIds) {
      mentionCountByRelation[rid] = (mentionCountByRelation[rid] ?? 0) + 1;
    }
    for (final eid in entry.entityIds) {
      firstEntryByEntity.putIfAbsent(eid, () => entry.id);
    }
  }
  final activePairCount = <String, int>{};
  for (final r in activeRelations) {
    final key = '${r.source} ${r.target}';
    activePairCount[key] = (activePairCount[key] ?? 0) + 1;
  }

  final uncertainRelations = activeRelations
      .map((r) {
        var score = 0;
        if ((mentionCountByRelation[r.id] ?? 0) <= 1) score++;
        final se = firstEntryByEntity[r.source];
        final te = firstEntryByEntity[r.target];
        if (se != null && te != null && se != te) score++;
        if ((activePairCount['${r.source} ${r.target}'] ?? 0) <= 1) score++;
        return UncertainRelation(
          source: state.entities[r.source]?.name ?? r.source,
          label: r.label,
          target: state.entities[r.target]?.name ?? r.target,
          score: score,
        );
      })
      .where((r) => r.score >= 2)
      .toList()
    ..sort((a, b) => b.score.compareTo(a.score));

  // bridgeCandidates
  final neighbors = <String, Set<String>>{};
  final directlyLinked = <String>{};
  for (final r in activeRelations) {
    neighbors.putIfAbsent(r.source, () => {}).add(r.target);
    neighbors.putIfAbsent(r.target, () => {}).add(r.source);
    final key = [r.source, r.target]..sort();
    directlyLinked.add(key.join(' '));
  }
  final ids = neighbors.keys.toList();
  final bridges = <({String a, String b, int shared})>[];
  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      final a = ids[i], b = ids[j];
      final key = ([a, b]..sort()).join(' ');
      if (directlyLinked.contains(key)) continue;
      final na = neighbors[a]!, nb = neighbors[b]!;
      final shared = na.intersection(nb).length;
      if (shared > 0) bridges.add((a: a, b: b, shared: shared));
    }
  }
  bridges.sort((x, y) => y.shared.compareTo(x.shared));
  final bridgeCandidates = bridges
      .take(6)
      .map((br) => (
            state.entities[br.a]?.name ?? br.a,
            state.entities[br.b]?.name ?? br.b,
          ))
      .toList();

  // openQuestions
  final openQuestions = entities
      .expand((e) => (e.questions ?? []).map((q) => OpenQuestion(entity: e.name, question: q)))
      .take(12)
      .toList();

  return Agenda(
    thinEntities: thinEntities.take(10).map((e) => e.name).toList(),
    justMentioned: justMentioned,
    uncertainRelations: uncertainRelations.take(3).toList(),
    bridgeCandidates: bridgeCandidates,
    openQuestions: openQuestions,
    entityCount: entities.length,
    relationCount: activeRelations.length,
  );
}
```

### `lib/logic/conversation_policy.dart`

```dart
// Timing constants — single source of truth
const silenceFlushMs = 2000;
const endpointingMs = 1000;
const finalChunkDebounceMs = 1400;
const pauseDeferralMs = 900;
const maxPauseDeferrals = 2;
const entityWordTarget = 100;
const focusBatchSize = 5;
const agentMessageLingerMs = 5000;
const followUpMaxWords = 20;
const sentenceIdleMs = 700;
const sentenceMinChars = 6;

final midSentenceTailRe = RegExp(
  r'\b(and|but|or|because|so|however|um|uh|like|well|the|a|an|to|of|in|with|for|that|while|then|though|although|since)$',
  caseSensitive: false,
);

// Paste the full GEMINI_LIVE_SYSTEM_INSTRUCTION string here verbatim.
// (Provided separately below as a const String geminiLiveSystemInstruction = '''...''';)
```

**IMPORTANT:** In `conversation_policy.dart`, define `geminiLiveSystemInstruction` as a Dart triple-quoted const string. Copy the exact content of the `GEMINI_LIVE_SYSTEM_INSTRUCTION` export from the original `conversation-policy.ts` file verbatim — every paragraph, tier, and constraint matters for the agent's behavior. The string is ~80 lines. Do not summarize or paraphrase it.

---

## Gemini Live WebSocket client

### `lib/services/gemini_live_client.dart`

The Gemini Live protocol runs over a WebSocket to:

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<API_KEY>
```

**Message types the client sends:**

1. `BidiGenerateContentSetup` — first message, sent once on connect
2. `BidiGenerateContentRealtimeInput` — audio chunks (base64 PCM 16-bit 16kHz)
3. `BidiGenerateContentClientContent` — text turns
4. `BidiGenerateContentToolResponse` — response to a tool call

**Message types the client receives:**

1. `BidiGenerateContentSetupComplete` — confirms setup
2. `BidiGenerateContentServerContent` — transcript chunks and/or audio chunks
3. `BidiGenerateContentToolCall` — model is requesting a tool invocation

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef OnTranscript = void Function(String text, bool isFinal);
typedef OnAudio = void Function(Uint8List pcm16);
typedef OnToolCall = Future<Map<String, dynamic>> Function(String toolName, Map<String, dynamic> args);
typedef OnTurnComplete = void Function();

class GeminiLiveClient {
  final String apiKey;
  final String model;
  final String systemInstruction;
  final String voice;
  final List<Map<String, dynamic>> tools;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  OnTranscript? onTranscript;
  OnAudio? onAudio;
  OnToolCall? onToolCall;
  OnTurnComplete? onTurnComplete;
  void Function()? onSetupComplete;
  void Function(Object)? onError;

  GeminiLiveClient({
    required this.apiKey,
    required this.model,
    required this.systemInstruction,
    required this.voice,
    required this.tools,
  });

  Future<void> connect() async {
    final uri = Uri.parse(
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=$apiKey',
    );
    _channel = WebSocketChannel.connect(uri);
    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (e) => onError?.call(e),
      onDone: () {},
    );
    await _sendSetup();
  }

  Future<void> _sendSetup() async {
    final setup = {
      'setup': {
        'model': 'models/$model',
        'system_instruction': {
          'parts': [{'text': systemInstruction}],
        },
        'generation_config': {
          'response_modalities': ['AUDIO'],
          'speech_config': {
            'voice_config': {
              'prebuilt_voice_config': {'voice_name': voice},
            },
          },
        },
        'tools': tools,
      },
    };
    _channel!.sink.add(jsonEncode(setup));
  }

  void sendAudio(Uint8List pcm16) {
    final b64 = base64.encode(pcm16);
    _channel!.sink.add(jsonEncode({
      'realtime_input': {
        'audio': {
          'data': b64,
          'mime_type': 'audio/pcm;rate=16000',
        },
      },
    }));
  }

  void sendText(String text, {bool endOfTurn = true}) {
    _channel!.sink.add(jsonEncode({
      'client_content': {
        'turns': [
          {'role': 'user', 'parts': [{'text': text}]},
        ],
        'turn_complete': endOfTurn,
      },
    }));
  }

  void respondToTool(String callId, Map<String, dynamic> result) {
    _channel!.sink.add(jsonEncode({
      'tool_response': {
        'function_responses': [
          {'id': callId, 'response': {'output': result}},
        ],
      },
    }));
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;

    if (msg.containsKey('setupComplete')) {
      onSetupComplete?.call();
      return;
    }

    if (msg.containsKey('toolCall')) {
      final calls = (msg['toolCall']['functionCalls'] as List<dynamic>);
      for (final call in calls) {
        final callMap = call as Map<String, dynamic>;
        final name = callMap['name'] as String;
        final id = callMap['id'] as String;
        final args = (callMap['args'] as Map<String, dynamic>?) ?? {};
        onToolCall?.call(name, args).then((result) => respondToTool(id, result));
      }
      return;
    }

    if (msg.containsKey('serverContent')) {
      final content = msg['serverContent'] as Map<String, dynamic>;
      final turnComplete = content['turnComplete'] == true;

      final parts = (content['modelTurn']?['parts'] as List<dynamic>?) ?? [];
      for (final part in parts) {
        final p = part as Map<String, dynamic>;
        if (p.containsKey('text')) {
          onTranscript?.call(p['text'] as String, turnComplete);
        }
        if (p.containsKey('inlineData')) {
          final data = p['inlineData'] as Map<String, dynamic>;
          if ((data['mime_type'] as String).startsWith('audio/')) {
            final bytes = base64.decode(data['data'] as String);
            onAudio?.call(bytes);
          }
        }
      }

      // Also look for input transcription (user's speech → text)
      if (content.containsKey('inputTranscription')) {
        final t = content['inputTranscription'] as Map<String, dynamic>;
        onTranscript?.call(t['text'] as String? ?? '', turnComplete);
      }

      if (turnComplete) onTurnComplete?.call();
    }
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }
}
```

---

## PCM audio capture

### `lib/audio/pcm_capture.dart`

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';

class PcmCapture {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  Future<void> start(void Function(Uint8List pcm16) onChunk) async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _sub = stream.listen(onChunk);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _recorder.stop();
  }

  Future<bool> hasPermission() async =>
      _recorder.hasPermission();
}
```

### `lib/audio/pcm_player.dart`

Play raw PCM 16-bit 16kHz audio received from Gemini Live. Use a StreamAudioSource with `just_audio`.

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:just_audio/just_audio.dart';

class PcmPlayer {
  final AudioPlayer _player = AudioPlayer();
  final _controller = StreamController<List<int>>.broadcast();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final source = _PcmStreamAudioSource(_controller.stream);
    await _player.setAudioSource(source);
    await _player.play();
  }

  void feed(Uint8List pcm16) {
    if (!_initialized) return;
    _controller.add(pcm16);
  }

  Future<void> dispose() async {
    await _controller.close();
    await _player.dispose();
  }
}

class _PcmStreamAudioSource extends StreamAudioSource {
  final Stream<List<int>> _stream;
  _PcmStreamAudioSource(this._stream)
      : super(tag: 'pcm-live');

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    return StreamAudioResponse(
      sourceLength: null,
      contentLength: null,
      offset: 0,
      stream: _stream,
      contentType: 'audio/wav', // wrap with WAV header or use raw
    );
  }
}
```

> **Note:** Raw PCM playback via just_audio requires a WAV header to be prepended to the stream (44-byte header for PCM 16-bit, 16kHz, mono). Write a helper `prependWavHeader(Uint8List pcm)` that prepends the correct RIFF/WAV header bytes before feeding to the player, or use the `flutter_sound` package which has native PCM feeding support.

---

## Graph extraction service

### `lib/services/extract_graph_service.dart`

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/graph_patch.dart';
import '../models/entity.dart';
import '../models/journal_state.dart';
import '../logic/noise_filter.dart';

const _extractionUrl =
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

// These are the two mode-specific system prompts. Copy them verbatim from
// src/lib/extract-graph.ts (WIKI_EXTRACTOR_PROMPT and GRANULAR_EXTRACTOR_PROMPT)
// in the origin repo. They are long (~70 lines each) — do not summarize.
const _wikiPrompt = '''<PASTE WIKI_EXTRACTOR_PROMPT VERBATIM HERE>''';
const _granularPrompt = '''<PASTE GRANULAR_EXTRACTOR_PROMPT VERBATIM HERE>''';

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
            'type': {'type': 'string', 'enum': ['person','place','organization','project','event','activity','concept','emotion','other']},
            'description': {'type': 'string'},
            'metadata': {'type': 'object'},
            'questions': {'type': 'array', 'items': {'type': 'string'}},
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

String _buildUserMessage(
  String text,
  JournalState state, {
  int maxContextEntities = 20,
  List<({String role, String text})> recentConversation = const [],
}) {
  final existing = state.entities.values.take(maxContextEntities).toList();
  final existingList = existing.isEmpty
      ? '(none yet)'
      : existing.map((e) => '- ${e.name} (${e.type.name})${e.description != null ? " - ${e.description}" : ""}').join('\n');

  final recent = recentConversation.take(4).toList();
  final recentList = recent.isEmpty
      ? '(none)'
      : recent.map((t) => '- ${t.role}: ${t.text}').join('\n');

  return '''EXISTING ENTITIES (reuse these spellings for the same thing):
$existingList

RECENT CONVERSATION (for pronoun resolution only — do NOT extract from these):
$recentList

NEW UTTERANCE:
"""$text"""''';
}

class ExtractGraphService {
  final String apiKey;
  ExtractGraphService({required this.apiKey});

  Future<GraphPatch> extract({
    required String text,
    required JournalState state,
    required String mode, // "wiki" | "granular"
    List<({String role, String text})> recentConversation = const [],
    int maxRetries = 2,
  }) async {
    final trimmed = text.trim();
    if (trimmed.length < 6) return GraphPatch.empty();

    final systemPrompt = mode == 'wiki' ? _wikiPrompt : _granularPrompt;
    final userMessage = _buildUserMessage(trimmed, state, recentConversation: recentConversation);

    final body = jsonEncode({
      'system_instruction': {
        'parts': [{'text': systemPrompt}],
      },
      'contents': [
        {'role': 'user', 'parts': [{'text': userMessage}]},
      ],
      'tools': [{'function_declarations': [_functionDeclaration]}],
      'tool_config': {'function_calling_config': {'mode': 'ANY'}},
      'generation_config': {'temperature': 0.0},
    });

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final res = await http.post(
          Uri.parse('$_extractionUrl?key=$apiKey'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        );

        if (res.statusCode == 429 && attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: 500 * (1 << attempt)));
          continue;
        }

        if (res.statusCode != 200) return GraphPatch.empty();

        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final parts = (json['candidates']?[0]?['content']?['parts'] as List?)
            ?.cast<Map<String, dynamic>>();
        if (parts == null) return GraphPatch.empty();

        for (final part in parts) {
          if (part.containsKey('functionCall') &&
              part['functionCall']['name'] == 'extract_graph') {
            final args = part['functionCall']['args'] as Map<String, dynamic>;
            final raw = GraphPatch.fromJson(args);
            return filterNoise(raw);
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
```

---

## Supabase service

### `lib/services/supabase_service.dart`

**Supabase tables (match this schema exactly):**

```sql
-- notebooks
create table notebooks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users not null,
  title text not null default 'Untitled',
  title_source text not null default 'auto',  -- 'ai' | 'user' | 'auto'
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  entity_count int not null default 0,
  summary text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- journal_entries
create table journal_entries (
  id text primary key,
  notebook_id uuid references notebooks not null,
  text text not null,
  created_at timestamptz not null,
  entity_ids text[] not null default '{}',
  relation_ids text[] not null default '{}'
);

-- entities
create table entities (
  id text not null,
  notebook_id uuid references notebooks not null,
  name text not null,
  type text not null,
  description text,
  metadata jsonb not null default '{}',
  mentions int not null default 1,
  first_seen timestamptz not null,
  last_seen timestamptz not null,
  questions text[],
  primary key (id, notebook_id)
);

-- relations
create table relations (
  id text not null,
  notebook_id uuid references notebooks not null,
  source text not null,
  target text not null,
  label text not null,
  metadata jsonb not null default '{}',
  created_at timestamptz not null,
  superseded_at timestamptz,
  primary key (id, notebook_id)
);

-- follow_ups
create table follow_ups (
  id text primary key,
  notebook_id uuid references notebooks not null,
  question text not null,
  reason text not null default '',
  target_entity_ids text[] not null default '{}',
  created_at timestamptz not null,
  answered boolean not null default false
);
```

RLS: enable on all tables, policies `user_id = auth.uid()` on notebooks; join via notebook_id for the rest.

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/journal_state.dart';
import '../models/entity.dart';
import '../models/relation.dart';
import '../models/journal_entry.dart';
import '../models/notebook.dart';

class SupabaseService {
  final SupabaseClient _client;
  SupabaseService(this._client);

  // --- Auth ---

  Future<void> signInWithEmail(String email, String password) =>
      _client.auth.signInWithPassword(email: email, password: password);

  Future<void> signUpWithEmail(String email, String password) =>
      _client.auth.signUp(email: email, password: password);

  Future<void> signOut() => _client.auth.signOut();

  User? get currentUser => _client.auth.currentUser;

  // --- Notebooks ---

  Future<Notebook?> ensureActiveNotebook() async {
    final userId = currentUser?.id;
    if (userId == null) return null;

    final res = await _client
        .from('notebooks')
        .select()
        .eq('user_id', userId)
        .isFilter('ended_at', null)
        .order('started_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (res != null) return Notebook.fromJson(res);

    final created = await _client
        .from('notebooks')
        .insert({'user_id': userId, 'title': 'Untitled'})
        .select()
        .single();
    return Notebook.fromJson(created);
  }

  Future<void> endNotebook(String notebookId) async {
    await _client
        .from('notebooks')
        .update({'ended_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', notebookId);
  }

  // --- Load state ---

  Future<JournalState> loadState(String notebookId) async {
    final results = await Future.wait([
      _client.from('journal_entries').select().eq('notebook_id', notebookId),
      _client.from('entities').select().eq('notebook_id', notebookId),
      _client.from('relations').select().eq('notebook_id', notebookId),
    ]);

    final entries = (results[0] as List).map((r) => JournalEntry.fromJson(r as Map<String, dynamic>)).toList();
    final entities = {
      for (final r in results[1] as List)
        (r as Map<String, dynamic>)['id'] as String: Entity.fromJson(r),
    };
    final relations = {
      for (final r in results[2] as List)
        (r as Map<String, dynamic>)['id'] as String: Relation.fromJson(r),
    };

    return JournalState(
      entries: entries,
      entities: entities,
      relations: relations,
      followUps: [],
    );
  }

  // --- Save state (snapshot replace) ---

  Future<void> saveState(String notebookId, JournalState state) async {
    await _client.from('journal_entries').delete().eq('notebook_id', notebookId);
    await _client.from('entities').delete().eq('notebook_id', notebookId);
    await _client.from('relations').delete().eq('notebook_id', notebookId);

    if (state.entries.isNotEmpty) {
      await _client.from('journal_entries').insert(
        state.entries.map((e) => {...e.toJson(), 'notebook_id': notebookId}).toList(),
      );
    }
    if (state.entities.isNotEmpty) {
      await _client.from('entities').insert(
        state.entities.values.map((e) => {...e.toJson(), 'notebook_id': notebookId}).toList(),
      );
    }
    if (state.relations.isNotEmpty) {
      await _client.from('relations').insert(
        state.relations.values.map((r) => {...r.toJson(), 'notebook_id': notebookId}).toList(),
      );
    }

    await _client
        .from('notebooks')
        .update({'entity_count': state.entities.length, 'updated_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', notebookId);
  }
}
```

---

## State management (Riverpod)

### `lib/providers/journal_provider.dart`

The `JournalNotifier` owns the live session: it holds `JournalState`, runs the extraction loop, and communicates with the Gemini Live client.

```dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/journal_state.dart';
import '../models/graph_patch.dart';
import '../logic/merge.dart' as logic;
import '../logic/agenda.dart' as logic;
import '../logic/conversation_policy.dart';
import '../services/extract_graph_service.dart';
import '../services/supabase_service.dart';
import '../services/gemini_live_client.dart';
import '../audio/pcm_capture.dart';
import '../audio/pcm_player.dart';
import '../env.dart';

enum SessionStatus { idle, connecting, live, ending, error }

class JournalNotifier extends Notifier<JournalState> {
  JournalState build() => JournalState.empty();

  // --- Private ---
  GeminiLiveClient? _live;
  PcmCapture? _capture;
  PcmPlayer? _player;
  Timer? _sentenceIdleTimer;
  Timer? _extractAbortTimer;
  String _turnAccumulator = '';
  final _conversation = <({String role, String text})>[];
  String? _activeNotebookId;
  SessionStatus _status = SessionStatus.idle;

  SessionStatus get status => _status;

  // Sentence-boundary detection: fires on .!? or sentenceIdleMs silence
  void _onTranscriptChunk(String chunk, bool isFinal) {
    _turnAccumulator += chunk;
    final trimmed = _turnAccumulator.trim();

    // Punctuation boundary
    if (RegExp(r'[.!?]\s*$').hasMatch(trimmed) && trimmed.length >= sentenceMinChars) {
      _sentenceIdleTimer?.cancel();
      _processGraphUpdate(trimmed);
      return;
    }

    // Idle timer
    _sentenceIdleTimer?.cancel();
    if (trimmed.length >= sentenceMinChars) {
      _sentenceIdleTimer = Timer(
        const Duration(milliseconds: sentenceIdleMs),
        () => _processGraphUpdate(_turnAccumulator.trim()),
      );
    }

    if (isFinal) {
      _sentenceIdleTimer?.cancel();
      if (trimmed.length >= sentenceMinChars) _processGraphUpdate(trimmed);
      _turnAccumulator = '';
      _conversation.add((role: 'user', text: trimmed));
      if (_conversation.length > 16) _conversation.removeRange(0, _conversation.length - 16);
    }
  }

  // Abort-and-supersede: cancel in-flight extraction when a newer sentence arrives
  Completer<void>? _inFlight;

  Future<void> _processGraphUpdate(String text) async {
    _inFlight?.complete(); // signal the old call to abandon
    final thisCall = Completer<void>();
    _inFlight = thisCall;

    final extractService = ExtractGraphService(apiKey: Env.geminiApiKey);
    try {
      final patch = await extractService.extract(
        text: text,
        state: state,
        mode: 'granular',
        recentConversation: _conversation,
      );
      if (thisCall.isCompleted) return; // superseded
      final result = logic.merge(state, text, patch);
      state = result.next;
      _saveStateDebounced();
    } catch (_) {
      if (!thisCall.isCompleted) thisCall.complete();
    }
  }

  Timer? _saveDebounce;
  void _saveStateDebounced() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      if (_activeNotebookId != null) {
        // fire and forget
        SupabaseService(/* inject client */).saveState(_activeNotebookId!, state);
      }
    });
  }

  // get_graph_summary tool for Gemini Live
  Map<String, dynamic> _buildGraphSummary() {
    final agenda = logic.buildAgenda(state);
    return {
      'mode': 'granular',
      'entityCount': agenda.entityCount,
      'relationCount': agenda.relationCount,
      'thinEntities': agenda.thinEntities.take(5).toList(),
      'justMentioned': agenda.justMentioned,
      'uncertainRelations': agenda.uncertainRelations.map((r) => {
        'source': r.source,
        'label': r.label,
        'target': r.target,
        'score': r.score,
      }).toList(),
      'bridgeCandidates': agenda.bridgeCandidates.map((p) => [p.$1, p.$2]).toList(),
      'openQuestionsTop': agenda.openQuestions.take(5).map((q) => {'entity': q.entity, 'question': q.question}).toList(),
    };
  }

  Future<void> startSession() async {
    _status = SessionStatus.connecting;

    _player = PcmPlayer();
    await _player!.init();

    _live = GeminiLiveClient(
      apiKey: Env.geminiApiKey,
      model: 'gemini-live-2.5-flash-preview',
      systemInstruction: geminiLiveSystemInstruction,
      voice: 'Aoede',
      tools: [
        {
          'function_declarations': [{
            'name': 'get_graph_summary',
            'description': 'Returns the current knowledge graph state and agenda for the agent to plan its next question.',
            'parameters': {'type': 'object', 'properties': {}},
          }],
        },
      ],
    )
      ..onTranscript = _onTranscriptChunk
      ..onAudio = (pcm) => _player?.feed(pcm)
      ..onTurnComplete = () {
        _conversation.add((role: 'agent', text: ''));
      }
      ..onToolCall = (name, args) async {
        if (name == 'get_graph_summary') return _buildGraphSummary();
        return {};
      }
      ..onSetupComplete = () {
        _status = SessionStatus.live;
      };

    await _live!.connect();

    _capture = PcmCapture();
    await _capture!.start((pcm) => _live?.sendAudio(pcm));
  }

  Future<void> endSession() async {
    _status = SessionStatus.ending;
    _sentenceIdleTimer?.cancel();
    _saveDebounce?.cancel();
    await _capture?.stop();
    await _live?.close();
    await _player?.dispose();
    if (_activeNotebookId != null) {
      await SupabaseService(/* inject client */).endNotebook(_activeNotebookId!);
    }
    _status = SessionStatus.idle;
    _live = null;
    _capture = null;
    _player = null;
  }
}

final journalProvider = NotifierProvider<JournalNotifier, JournalState>(
  JournalNotifier.new,
);
```

---

## Screens

### `lib/screens/auth/login_screen.dart`

Standard Supabase email/password login. Clean, minimal. Fields: email, password. Button: "Sign in". Link: "Create account" → signup. On success, `context.go('/journal')`. Handle `AuthException` errors inline.

### `lib/screens/auth/signup_screen.dart`

Fields: email, password, confirm password. On success, tell user to check email for magic link (if email confirmation is required). Handle errors inline.

### `lib/screens/journal/journal_screen.dart`

The main orchestration screen. Full-screen layout:

1. **Background** — `GraphCanvas` fills the entire screen, semi-transparent, showing the live knowledge graph.
2. **Bottom center** — `MicButton` (large, pulsing when live). Tap to start/stop session.
3. **Top overlay** — slim status bar showing entity count + relation count.
4. **Mid-screen** — `TranscriptOverlay` shows the most recent utterance text, fading out after 4 seconds.
5. **Top-right** — thin `GraphLegend` (collapses by default, tap to expand).

The screen subscribes to `journalProvider` and `journalProvider.notifier`. On mic tap: if `status == idle`, call `startSession()`; otherwise call `endSession()`.

### `lib/screens/journal/graph_canvas.dart`

Custom force-directed graph renderer using `CustomPainter`. No third-party graph package.

**Force simulation (simplified Fruchterman-Reingold, runs every 16ms via `Ticker`):**

- Each `Entity` (non-superseded) is a node with position `(x, y)` initialized randomly within canvas bounds.
- Each active `Relation` is an edge.
- Forces per tick:
  - **Repulsion** between all node pairs: `F = k² / distance`, pushes apart
  - **Attraction** along edges: `F = distance² / k`, pulls connected nodes together
  - **Centering**: gentle pull toward canvas center
  - **Damping**: velocity × 0.85 per tick
- Stop simulation after 200 ticks of low movement (or keep running at low frequency for live updates).

**Painting:**

- Edges: thin lines, color by relation type (or uniform gray)
- Nodes: circles, color by `EntityType` (use the same color map as the web app: person=blue, place=green, organization=orange, project=purple, event=red, activity=teal, concept=yellow, emotion=pink, other=gray)
- Node labels: entity name, clamped, 10sp

**Interactivity:**

- Pan: `GestureDetector` `onPanUpdate`
- Zoom: `onScaleUpdate`
- Tap a node: show entity detail bottom sheet

**New entity animation:** when a new entity appears, it fades in from opacity 0 → 1 over 300ms.

### `lib/screens/journal/transcript_overlay.dart`

Shows `_turnAccumulator` text from `JournalNotifier`. Auto-clears after 4 seconds of no new text. Semi-transparent card centered mid-screen. Max 3 lines, overflow ellipsis.

### `lib/screens/journal/mic_button.dart`

Large circular button (80px diameter). When `status == idle`: microphone icon, `Colors.white`. When `status == live`: pulsing ring animation (scale 1.0→1.3, opacity 1→0, repeating), `Colors.red`. When `status == connecting`: spinner.

Use `AnimationController` + `CurvedAnimation` for the pulse ring. The ring is a separate `Container` with border, animating in a `Stack`.

---

## Navigation (`lib/app.dart`)

```dart
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/journal/journal_screen.dart';
import 'providers/auth_provider.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authProvider);
  return GoRouter(
    initialLocation: '/journal',
    redirect: (context, state) {
      final isLoggedIn = auth.valueOrNull != null;
      final isAuthRoute = state.matchedLocation.startsWith('/auth');
      if (!isLoggedIn && !isAuthRoute) return '/auth/login';
      if (isLoggedIn && isAuthRoute) return '/journal';
      return null;
    },
    routes: [
      GoRoute(path: '/auth/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/auth/signup', builder: (_, __) => const SignupScreen()),
      GoRoute(path: '/journal', builder: (_, __) => const JournalScreen()),
    ],
  );
});
```

---

## iOS-specific setup

In `ios/Runner/Info.plist`, add:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Lumen uses your microphone to capture your voice journal entries.</string>
<key>NSCameraUsageDescription</key>
<string>Not used.</string>
```

In `ios/Podfile`:

```ruby
platform :ios, '16.0'
```

Run `pod install` in `ios/` after `flutter pub get`.

---

## Tests

Write these four test files with actual assertions — no placeholder tests.

### `test/slugify_test.dart`

- `slugify("Project Atlas")` == `"project-atlas"`
- `slugify("CS246")` == `"cs246"`
- `slugify("")` starts with `"e-"`
- `slugify("Héros")` == `"heros"`

### `test/noise_filter_test.dart`

- Patch with `["I", "Maya", "today"]` → only `["Maya"]` in kept entities
- Relation `I→Maya` dropped when `"I"` is filtered
- Relation `Maya→Brooklyn` kept (Brooklyn not in noise)
- Extra noise `{"lumen"}` filters entity named "Lumen"

### `test/merge_test.dart`

- New entity appears, `mentions == 1`
- Re-mention increments to `2`
- Supersede stamps `supersededAt`; re-assertion clears it (self-heal)
- Questions deduped, newest-first, capped at 8
- Relation backfill: endpoint entities in prior state get mention bumped

### `test/agenda_test.dart`

- Single-mention entity classified as thin
- Fresh relation scores ≥ 2 in uncertainRelations
- Bridge candidate appears when two entities share a neighbor but have no direct link
- openQuestions populated from entity.questions in wiki mode

---

## Implementation order

Implement in this order to keep the app buildable at each step:

1. `pubspec.yaml` + `flutter pub get`
2. `lib/env.dart` + `.env` loading in `main.dart`
3. All models + `build_runner` generated code
4. Pure logic: `slugify`, `noise_filter`, `merge`, `agenda`, `conversation_policy`
5. All four unit tests — they must pass before proceeding
6. `supabase_service.dart` + Supabase init in `main.dart`
7. Auth screens + `auth_provider` + router
8. `pcm_capture.dart` + `pcm_player.dart`
9. `gemini_live_client.dart`
10. `extract_graph_service.dart` (paste verbatim prompts from origin)
11. `journal_provider.dart`
12. `graph_canvas.dart` (force simulation + painter)
13. `journal_screen.dart` + `mic_button.dart` + `transcript_overlay.dart`
14. iOS permissions + pod install
15. Run on simulator: test auth → session start → speak → see graph update

---

## Critical invariants to preserve

1. **Sentence-boundary fires mid-turn** — do not wait for the turn to end before extracting. The 700ms idle timer and punctuation check both fire while the user is still speaking.
2. **Abort supersedes** — `_processGraphUpdate` must cancel the previous in-flight extraction. Only the most recent sentence writes to state. Use the `Completer` pattern shown above or an `int generation` counter.
3. **Self-heal** — re-asserting a superseded relation MUST clear `supersededAt`. The `Relation` constructor in the upsert branch intentionally omits `supersededAt`.
4. **Gemini Live responds to tool calls immediately** — `onToolCall` must call `respondToTool` before returning, even if the response is empty. Failure to respond blocks the model's turn.
5. **No graph data visible to user in UI** — the graph renders visually but the agent NEVER speaks about "thin entities", "coverage", "bridges", or graph state. The system prompt enforces this but the UI must never surface debug/graph metadata in the transcript overlay.
6. **Save is snapshot-replace** — `saveState` deletes all rows for the notebook, then re-inserts the full current state. This is intentional (simple, avoids diff/upsert complexity for v1).
7. **`get_graph_summary` returns entity names, not IDs** — the Live model needs human-readable names for its questions. IDs (slugs) are internal to the merge/storage layer only.

---

## What NOT to build in v1

- Obsidian export
- Session history / notebook list screen
- Wiki extraction mode (implement `"granular"` only; leave `"wiki"` mode stubs)
- Push notifications
- iPad / landscape layout
- Any analytics

---

## Definition of done

- [ ] `flutter test` passes (all 4 test files)
- [ ] App builds on iOS simulator (`flutter build ios --simulator`)
- [ ] Auth flow works: sign up → verify → sign in → journal screen
- [ ] Tapping mic starts recording and opens WebSocket to Gemini Live
- [ ] Speaking a sentence with a name triggers extraction and adds a node to the graph canvas
- [ ] Agent replies with audio (voice plays through speaker)
- [ ] Graph canvas renders nodes and edges, updates within 2 seconds of new extraction
- [ ] Session end stamps `ended_at` on the notebook in Supabase
- [ ] App launches cold with a prior session's graph already loaded (hydrate on mount)
