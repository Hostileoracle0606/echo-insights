import 'dart:convert';

import '../models/journal_state.dart';
import '../services/gemini_live_client.dart' show HistoryTurn;
import 'session_state.dart';

/// EC-05: the context a rebuilt Live session starts from, built only from
/// stored state:
/// - a continuation line (the conversation goes on; no greeting, no recap),
/// - the working set: entities ranked by relevance (talked about now, then
///   their neighbours, then recent), each with its current facts and links,
/// - the session state (EC-04) and the planning fields the prompt uses,
/// - the last few turns, verbatim.
///
/// Bounded by [materialiseContext]'s token budget, deterministic for the
/// same inputs in any order, and never two versions of one fact.

const continuationLine =
    "[continuation] This conversation is continuing on a new connection after a "
    "short pause. Don't greet, recap or restart: carry on from the last turn "
    "below as if nothing happened, and don't repeat anything already said.";

/// The turns replayed verbatim.
const maxRecentTurns = 6;
const maxRecentChars = 2400;
const _maxDescription = 160;

/// A fact of the working set (get_current_facts).
class WorkingFact {
  const WorkingFact({
    required this.entityId,
    required this.attribute,
    this.valueNum,
    this.valueText,
    this.unit,
    required this.status,
    this.eventAt,
  });

  final String entityId;
  final String attribute;
  final num? valueNum;
  final String? valueText;
  final String? unit;
  final String status;
  final String? eventAt;

  /// Null when [json] is not a fact row.
  static WorkingFact? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final entityId = json['entityId'];
    final attribute = json['attribute'];
    final status = json['status'];
    if (entityId is! String || attribute is! String || status is! String) return null;
    final num? value = json['valueNum'] is num ? json['valueNum'] as num : null;
    final String? text = json['valueText'] is String ? json['valueText'] as String : null;
    if (value == null && text == null) return null;
    return WorkingFact(
      entityId: entityId,
      attribute: attribute,
      valueNum: value,
      valueText: text,
      unit: json['unit'] is String ? json['unit'] as String : null,
      status: status,
      eventAt: json['eventAt'] is String ? json['eventAt'] as String : null,
    );
  }

  String get _value {
    final v = valueNum != null
        ? (valueNum == valueNum!.roundToDouble() ? valueNum!.toInt().toString() : '$valueNum')
        : valueText!;
    return unit == null ? v : '$v $unit';
  }

  /// "amount: 8000 USD", "amount (planned): 10000 USD by 2027-01-01".
  String render() {
    final label = switch (status) {
      'proposed' => '$attribute (planned)',
      'cancelled' => '$attribute (called off)',
      _ => attribute,
    };
    final when = eventAt != null && status != 'confirmed' ? ' by ${eventAt!.substring(0, 10)}' : '';
    return '$label: $_value$when';
  }
}

class MaterialisedContext {
  const MaterialisedContext({
    required this.context,
    required this.turns,
    required this.estimatedTokens,
  });

  final String context;
  final List<HistoryTurn> turns;
  final int estimatedTokens;
}

/// A rough count: about four characters a token.
int estimateTokens(String text) => (text.length / 4).ceil();

MaterialisedContext materialiseContext({
  required JournalState graph,
  required List<WorkingFact> facts,
  required SessionState session,
  required List<HistoryTurn> recentTurns,
  required Set<String> activeEntityIds,
  required Map<String, dynamic> planning,
  required DateTime now,
  int tokenBudget = 1500,
}) {
  final turns = _recent(recentTurns);
  final turnTokens = turns.fold<int>(0, (n, t) => n + estimateTokens(t.text));

  final rows = [for (final id in _ranked(graph, activeEntityIds, now)) _row(graph, id, facts)];
  final summary = <String, dynamic>{
    ..._trimmedPlanning(planning),
    'sessionState': session.toSummary(),
    'workingSet': <Map<String, dynamic>>[],
  };
  String render() => '$continuationLine\n[graph summary] ${jsonEncode(summary)}';

  for (final row in rows) {
    (summary['workingSet'] as List).add(row);
    if (estimateTokens(render()) + turnTokens > tokenBudget) {
      (summary['workingSet'] as List).removeLast();
      break;
    }
  }
  final context = render();
  return MaterialisedContext(
    context: context,
    turns: turns,
    estimatedTokens: estimateTokens(context) + turnTokens,
  );
}

List<HistoryTurn> _recent(List<HistoryTurn> turns) {
  final picked = <HistoryTurn>[];
  var chars = 0;
  for (final turn in turns.reversed) {
    final text = turn.text.trim();
    if (text.isEmpty) continue;
    if (picked.length >= maxRecentTurns || chars + text.length > maxRecentChars) break;
    picked.add((fromUser: turn.fromUser, text: text));
    chars += text.length;
  }
  return picked.reversed.toList(growable: false);
}

/// Entity ids, most relevant first: talked about now, then their one-hop
/// neighbours, then by how recently and how often they came up. Ties go by
/// id, so the order never depends on map order.
List<String> _ranked(JournalState graph, Set<String> active, DateTime now) {
  final neighbours = <String>{};
  for (final r in graph.relations.values) {
    if (r.supersededAt != null) continue;
    if (active.contains(r.source)) neighbours.add(r.target);
    if (active.contains(r.target)) neighbours.add(r.source);
  }
  double score(String id) {
    final e = graph.entities[id]!;
    final days = now.difference(e.lastSeen).inHours / 24;
    return (active.contains(id) ? 4 : 0) +
        (neighbours.contains(id) ? 2 : 0) +
        1 / (1 + (days < 0 ? 0 : days)) +
        (e.mentions > 10 ? 10 : e.mentions) / 20;
  }

  final ids = graph.entities.keys.toList()..sort();
  final scores = {for (final id in ids) id: score(id)};
  ids.sort((a, b) {
    final byScore = scores[b]!.compareTo(scores[a]!);
    return byScore != 0 ? byScore : a.compareTo(b);
  });
  return ids;
}

Map<String, dynamic> _row(JournalState graph, String id, List<WorkingFact> facts) {
  final e = graph.entities[id]!;
  final description = e.description?.trim();
  final factLines = <String>{
    for (final f in [...facts.where((f) => f.entityId == id)]
      ..sort((a, b) {
        final byAttr = a.attribute.compareTo(b.attribute);
        if (byAttr != 0) return byAttr;
        return _statusOrder(a.status).compareTo(_statusOrder(b.status));
      }))
      f.render(),
  }.toList();
  final links = <String>{
    for (final r in graph.relations.values)
      if (r.supersededAt == null && r.source == id && graph.entities[r.target] != null)
        '${r.label} ${graph.entities[r.target]!.name}'
      else if (r.supersededAt == null && r.target == id && graph.entities[r.source] != null)
        '${graph.entities[r.source]!.name} ${r.label}',
  }.toList()
    ..sort();
  return {
    'name': e.name,
    'type': e.type.name,
    if (description != null && description.isNotEmpty)
      'description': description.length <= _maxDescription
          ? description
          : '${description.substring(0, _maxDescription)}…',
    if (factLines.isNotEmpty) 'facts': factLines,
    if (links.isNotEmpty) 'links': links,
  };
}

int _statusOrder(String status) => switch (status) {
      'confirmed' => 0,
      'proposed' => 1,
      _ => 2,
    };

/// The planning fields the prompt reads, trimmed to what a turn needs.
Map<String, dynamic> _trimmedPlanning(Map<String, dynamic> planning) {
  List<dynamic> take(String key, int max) {
    final value = planning[key];
    if (value is! List) return const [];
    return value.length <= max ? value : value.sublist(0, max);
  }

  return {
    if (planning['mode'] != null) 'mode': planning['mode'],
    'thinEntities': take('thinEntities', 5),
    'openQuestionsTop': take('openQuestionsTop', 3),
    'bridgeCandidates': take('bridgeCandidates', 2),
    'probedThisSession': take('probedThisSession', 20),
    'recentAgentQuestions': take('recentAgentQuestions', 8),
  };
}
