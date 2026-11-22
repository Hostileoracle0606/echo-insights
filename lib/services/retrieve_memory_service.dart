import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic/relative_time.dart';
import '../models/entity.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/memory_quote.dart';
import '../models/relation.dart';
import '../providers/supabase_provider.dart';

/// Memory retrieval for extraction and the get_relevant_memory tool; tests
/// substitute a fake.
final retrieveMemoryServiceProvider = Provider<RetrieveMemoryService>(
  (ref) => RetrieveMemoryService(ref.watch(supabaseClientProvider)),
);

String _iso(DateTime d) => d.toUtc().toIso8601String();

Map<String, dynamic> _entity(Entity e) => {
      'id': e.id,
      'name': e.name,
      'type': e.type.name,
      if (e.description != null) 'description': e.description,
      'metadata': e.metadata,
      'mentions': e.mentions,
      'firstSeen': _iso(e.firstSeen),
      'lastSeen': _iso(e.lastSeen),
      if (e.questions != null) 'questions': e.questions,
    };

Map<String, dynamic> _relation(Relation r) => {
      'id': r.id,
      'source': r.source,
      'target': r.target,
      'label': r.label,
      'metadata': r.metadata,
      'createdAt': _iso(r.createdAt),
      if (r.supersededAt != null) 'supersededAt': _iso(r.supersededAt!),
    };

Map<String, dynamic> _entry(JournalEntry en) => {
      'id': en.id,
      'text': en.text,
      'createdAt': _iso(en.createdAt),
      'entityIds': en.entityIds,
      'relationIds': en.relationIds,
    };

/// Serialize JournalState into graphloop's GraphState shape (camelCase keys,
/// ISO-8601 UTC timestamps). NOT the Dart models' snake_case toJson() — the
/// edge function's retrieve() reads camelCase (lastSeen, entityIds, …).
/// followUps / askedQuestions are intentionally dropped (retrieval never uses
/// them), matching the web app's toGraphState.
Map<String, dynamic> stateToGraphloop(JournalState state) => {
      'entities': {
        for (final e in state.entities.values) e.id: _entity(e),
      },
      'relations': {
        for (final r in state.relations.values) r.id: _relation(r),
      },
      'entries': state.entries.map(_entry).toList(),
    };

const int retrieveMemoryContractVersion = 1;
const int retrieveMemoryContractVersionV2 = 2;
const int retrieveMemoryContractVersionV3 = 3;
const bool memoryQueryRoutingEnabled =
    bool.fromEnvironment('MEMORY_QUERY_ROUTING_ENABLED');

/// Which memory retrieve-memory searches. [user] reads the user's merged
/// graph across every notebook on the server and answers v2 with quotes;
/// [notebook] searches the graph the app sends and answers v1 (old clients).
enum RetrievalScope { notebook, user }

/// Successful response from the versioned retrieve-memory interface (v1 or
/// v2). v1 responses carry no quotes.
class MemoryRetrieval {
  final String context;
  final List<String> entityIds;
  final List<MemoryQuote> quotes;
  final MemoryVerdict? verdict;

  const MemoryRetrieval({
    required this.context,
    required this.entityIds,
    this.quotes = const [],
    this.verdict,
  });

  static const empty = MemoryRetrieval(context: '', entityIds: []);
  static const insufficient = MemoryRetrieval(
      context: '',
      entityIds: [],
      verdict: MemoryVerdict(
          status: 'insufficient_evidence',
          text: 'I could not find enough evidence to answer that.',
          sourceIds: []));

  factory MemoryRetrieval.fromData(dynamic data) {
    if (data is! Map) {
      throw const FormatException('Invalid retrieve-memory response');
    }
    final version = data['version'];
    if (version != retrieveMemoryContractVersion &&
        version != retrieveMemoryContractVersionV2 &&
        version != retrieveMemoryContractVersionV3) {
      throw const FormatException(
          'Unsupported retrieve-memory contract version');
    }
    final context = data['context'];
    final ids = data['entityIds'];
    if (context is! String || ids is! List || ids.any((id) => id is! String)) {
      throw FormatException('Invalid retrieve-memory v$version response');
    }
    final quotes = <MemoryQuote>[];
    if (version == retrieveMemoryContractVersionV2 ||
        version == retrieveMemoryContractVersionV3) {
      final raw = data['quotes'];
      if (raw is! List ||
          (version == retrieveMemoryContractVersionV3 && raw.length > 3)) {
        throw const FormatException('Invalid retrieve-memory v2 response');
      }
      quotes.addAll(raw.map(MemoryQuote.fromData));
    }
    final verdict = version == retrieveMemoryContractVersionV3
        ? MemoryVerdict.fromData(data['verdict'])
        : null;
    if (verdict != null &&
        (context.isNotEmpty ||
            ids.isNotEmpty ||
            quotes
                .any((quote) => !verdict.sourceIds.contains(quote.entryId)))) {
      throw const FormatException('Invalid v3 evidence');
    }
    return MemoryRetrieval(
      context: context,
      entityIds: ids.cast<String>().toList(growable: false),
      quotes: List.unmodifiable(quotes),
      verdict: verdict,
    );
  }
}

class MemoryVerdict {
  final String status;
  final String text;
  final List<String> sourceIds;
  const MemoryVerdict(
      {required this.status, required this.text, required this.sourceIds});

  factory MemoryVerdict.fromData(dynamic data) {
    if (data is! Map ||
        !const [
          'supported',
          'clarification',
          'insufficient_evidence',
          'conversation'
        ].contains(data['status']) ||
        data['text'] is! String ||
        (data['text'] as String).trim().isEmpty ||
        data['sourceIds'] is! List ||
        (data['sourceIds'] as List).any((id) => id is! String)) {
      throw const FormatException('Invalid memory verdict');
    }
    return MemoryVerdict(
        status: data['status'] as String,
        text: data['text'] as String,
        sourceIds: List<String>.unmodifiable(
            (data['sourceIds'] as List).cast<String>()));
  }
}

/// What get_relevant_memory hands the model: the private context packet and
/// the user's own past words with when they said them. Never ids, titles or
/// anything else the model could read out as plumbing.
Map<String, dynamic> memoryToolResult(
  MemoryRetrieval retrieval, {
  DateTime? now,
}) =>
    retrieval.verdict != null
        ? {
            'status': retrieval.verdict!.status,
            'answer': retrieval.verdict!.text,
            // Open recall answers with the user's own words (dated, no ids).
            if (retrieval.quotes.isNotEmpty)
              'quotes': [
                for (final quote in retrieval.quotes)
                  {
                    'when': spokenWhen(quote.saidAt, now: now),
                    'text': quote.text
                  },
              ],
          }
        : {
            'context': retrieval.context,
            'quotes': [
              for (final quote in retrieval.quotes)
                {
                  'when': spokenWhen(quote.saidAt, now: now),
                  'text': quote.text
                },
            ],
          };

/// User-scope lookups answer Gemini's live tool call, which blocks Lumen
/// until it is answered; past this the call degrades to empty memory.
const Duration userScopeRetrieveTimeout = Duration(milliseconds: 3500);

typedef RetrieveMemoryInvoker = Future<dynamic> Function(
  Map<String, dynamic> body,
);

/// Calls the retrieve-memory Edge Function. Transport/provider failures degrade
/// to empty memory. Contract mismatches are rejected, logged distinctly, then
/// fail closed so retrieval cannot break journaling.
class RetrieveMemoryService {
  final RetrieveMemoryInvoker _invoke;

  RetrieveMemoryService(SupabaseClient client)
      : _invoke = ((body) async =>
            (await client.functions.invoke('retrieve-memory', body: body))
                .data);

  /// For tests only: [invoke] receives the request body and returns the
  /// response data.
  RetrieveMemoryService.withInvoker(this._invoke);

  Future<String> retrieve({
    required String query,
    required String notebookId,
    required JournalState state,
  }) async =>
      (await retrieveResult(
        query: query,
        notebookId: notebookId,
        state: state,
      ))
          .context;

  /// [state] is sent only for [RetrievalScope.notebook]; user scope reads the
  /// graph on the server. [timeout] bounds the whole call and degrades to
  /// empty memory like any other failure; it defaults to
  /// [userScopeRetrieveTimeout] for user scope and to none for notebook scope.
  Future<MemoryRetrieval> retrieveResult({
    required String query,
    required String notebookId,
    String? question,
    JournalState? state,
    RetrievalScope scope = RetrievalScope.notebook,
    Duration? timeout,
  }) async {
    final q = query.trim();
    final useV3 = memoryQueryRoutingEnabled && scope == RetrievalScope.user;
    final fallback =
        useV3 ? MemoryRetrieval.insufficient : MemoryRetrieval.empty;
    if (q.length < 2 ||
        (useV3 && (question == null || question.trim().isEmpty))) {
      return fallback;
    }
    final startedAt = DateTime.now();

    // Non-sensitive telemetry: outcome + counts only, never query/context text.
    void emit(String outcome, int contextLength, [int quoteCount = 0]) =>
        developer.log(
          'outcome=$outcome scope=${scope.name} qLen=${q.length} '
          'contextLen=$contextLength quoteCount=$quoteCount '
          'latencyMs=${DateTime.now().difference(startedAt).inMilliseconds}',
          name: 'lumen.memory',
        );

    try {
      final body = <String, dynamic>{
        'query': q,
        if (useV3) 'version': retrieveMemoryContractVersionV3,
        if (useV3) 'question': question!.trim(),
        'notebookId': notebookId,
        if (scope == RetrievalScope.user)
          'scope': 'user'
        else
          'state': stateToGraphloop(state ?? JournalState.empty()),
      };
      final limit = timeout ??
          (scope == RetrievalScope.user ? userScopeRetrieveTimeout : null);
      final call = _invoke(body);
      final data = await (limit == null ? call : call.timeout(limit));
      final result = MemoryRetrieval.fromData(data);
      if (useV3 && result.verdict == null) {
        throw const FormatException('Expected v3 verdict');
      }
      emit(
        result.context.isEmpty ? 'empty' : 'ok',
        result.context.length,
        result.quotes.length,
      );
      return result;
    } on TimeoutException {
      emit('timeout', 0);
      return fallback;
    } on FormatException {
      emit('contractError', 0);
      return fallback;
    } catch (_) {
      emit('error', 0);
      return fallback;
    }
  }
}
