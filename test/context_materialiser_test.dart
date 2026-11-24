import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/context_materialiser.dart';
import 'package:lumen/logic/session_state.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';

// EC-05: a rebuilt Live context built only from stored state: a continuation
// line, the working set (entities ranked by relevance with their current
// facts), the session state, and the last few turns. Bounded, deterministic,
// and never two versions of one fact.

final _now = DateTime.utc(2026, 11, 22, 18);

Entity _entity(String id, String name, EntityType type,
        {int daysAgo = 1, int mentions = 1, String? description}) =>
    Entity(
      id: id,
      name: name,
      type: type,
      description: description,
      metadata: const {},
      mentions: mentions,
      firstSeen: _now.subtract(Duration(days: daysAgo + 10)),
      lastSeen: _now.subtract(Duration(days: daysAgo)),
    );

Relation _relation(String source, String label, String target) => Relation(
      id: '${source}__${label}__$target',
      source: source,
      target: target,
      label: label,
      metadata: const {},
      createdAt: _now,
    );

final _graph = JournalState.empty().copyWith(
  entities: {
    for (final e in [
      _entity('priya', 'Priya', EntityType.person, daysAgo: 3),
      _entity('lisbon', 'Lisbon', EntityType.place, daysAgo: 30),
      _entity('savings-goal', 'savings goal', EntityType.concept, daysAgo: 0, mentions: 4),
      _entity('samsung', 'Samsung', EntityType.organization, daysAgo: 60),
      for (var i = 0; i < 40; i++)
        _entity('topic-$i', 'Topic $i', EntityType.concept,
            daysAgo: 90 + i, description: 'A long description ' * 10),
    ])
      e.id: e,
  },
  relations: {
    for (final r in [
      _relation('priya', 'moving_to', 'lisbon'),
      _relation('priya', 'works_at', 'samsung'),
    ])
      r.id: r,
  },
);

const _facts = [
  WorkingFact(entityId: 'savings-goal', attribute: 'amount', valueNum: 8000, unit: 'USD', status: 'confirmed'),
  WorkingFact(entityId: 'savings-goal', attribute: 'amount', valueNum: 10000, unit: 'USD', status: 'proposed'),
  WorkingFact(entityId: 'savings-goal', attribute: 'amount', valueNum: 8000, unit: 'USD', status: 'confirmed'),
];

final _turns = [
  for (var i = 0; i < 12; i++) (fromUser: i.isEven, text: 'Turn $i.'),
];

MaterialisedContext _build({
  Set<String> active = const {'priya'},
  List<WorkingFact> facts = _facts,
  JournalState? graph,
  int budget = 1500,
}) =>
    materialiseContext(
      graph: graph ?? _graph,
      facts: facts,
      session: const SessionState(
        openThreads: ['How do you feel about her move?'],
        register: 'stressed',
      ),
      recentTurns: _turns,
      activeEntityIds: active,
      planning: const {
        'mode': 'granular',
        'thinEntities': ['Samsung', 'Lisbon', 'a', 'b', 'c', 'd', 'e'],
        'recentAgentQuestions': ['Q?'],
      },
      now: _now,
      tokenBudget: budget,
    );

Map<String, dynamic> _summary(MaterialisedContext c) {
  final line = c.context
      .split('\n')
      .firstWhere((l) => l.startsWith('[graph summary] '));
  return jsonDecode(line.substring('[graph summary] '.length)) as Map<String, dynamic>;
}

void main() {
  test('it continues the conversation; it does not open a new one', () {
    final c = _build();
    expect(c.context, startsWith('[continuation] '));
    expect(c.context, contains("Don't greet"));
    expect(c.context, isNot(contains('[opening said]')));
  });

  test('only the last few turns are replayed, newest last', () {
    final c = _build();
    expect(c.turns.map((t) => t.text), [for (var i = 6; i < 12; i++) 'Turn $i.']);
  });

  test('active entities and their neighbours rank first', () {
    final names = [
      for (final row in _summary(_build())['workingSet'] as List) (row as Map)['name'],
    ];
    expect(names.take(3).toSet(), {'Priya', 'Lisbon', 'Samsung'});
    expect(names.indexOf('savings goal'), 3, reason: 'then the most recent');
  });

  test('facts appear once each; a plan is marked as a plan', () {
    final rows = _summary(_build(active: {'savings-goal'}))['workingSet'] as List;
    final goal = rows.firstWhere((r) => (r as Map)['name'] == 'savings goal') as Map;
    expect(goal['facts'], ['amount: 8000 USD', 'amount (planned): 10000 USD']);
  });

  test('links name the other end', () {
    final rows = _summary(_build())['workingSet'] as List;
    final priya = rows.firstWhere((r) => (r as Map)['name'] == 'Priya') as Map;
    expect(priya['links'], ['moving_to Lisbon', 'works_at Samsung']);
  });

  test('the session state and the planning fields come along, trimmed', () {
    final summary = _summary(_build());
    expect((summary['sessionState'] as Map)['openThreads'], ['How do you feel about her move?']);
    expect(summary['thinEntities'], hasLength(5));
    expect(summary['recentAgentQuestions'], ['Q?']);
  });

  test('the context stays within its token budget', () {
    for (final budget in [600, 1000, 1500, 3000]) {
      final c = _build(budget: budget);
      expect(c.estimatedTokens, lessThanOrEqualTo(budget), reason: 'budget $budget');
      expect(estimateTokens(c.context) + c.turns.fold<int>(0, (n, t) => n + estimateTokens(t.text)),
          c.estimatedTokens);
    }
    expect((_summary(_build(budget: 600))['workingSet'] as List).length,
        lessThan((_summary(_build(budget: 3000))['workingSet'] as List).length),
        reason: 'a smaller budget keeps fewer, the most relevant first');
  });

  test('the same state always produces the same context', () {
    final shuffled = JournalState.empty().copyWith(
      entities: Map.fromEntries(_graph.entities.entries.toList().reversed),
      relations: Map.fromEntries(_graph.relations.entries.toList().reversed),
    );
    final a = _build();
    final b = _build(graph: shuffled, facts: _facts.reversed.toList());
    expect(b.context, a.context);
    expect(b.turns.map((t) => t.text), a.turns.map((t) => t.text));
  });
}
