import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/session_brief.dart';
import 'model_inputs.dart';
import 'pseudonym_service.dart';

/// Calls a Supabase RPC and returns its JSON result.
typedef BriefRpc = Future<Object?> Function(
  String fn, [
  Map<String, dynamic>? params,
]);

class SessionBriefException implements Exception {
  const SessionBriefException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'SessionBriefException: $message'
      : 'SessionBriefException ($statusCode): $message';
}

/// The session brief (LM-40): asks the notebook runtime to write one
/// (`POST /v1/notebooks/{id}/brief`), reads the stored one, and marks it
/// played.
///
/// LM-56 (request v2, contracts/session-brief-v1.md): the transcript and
/// the memory lists are read here and their names swapped on the device;
/// the runtime returns the brief text unsaved. The names are swapped back,
/// the real opening line alone goes back for its audio (the one sentence
/// with real names Google's speech model hears), and the brief is saved
/// through `save_session_brief`.
/// The longest opening line the runtime's speak step takes (client-input.mjs).
const speakLineCap = 200;

/// The longest opening line save_session_brief stores.
const savedLineCap = 160;

class SessionBriefService {
  SessionBriefService({
    required String baseUrl,
    required Future<String?> Function() accessTokenProvider,
    required BriefRpc rpc,
    required ModelInputSource inputs,
    required PseudonymService pseudonyms,
    http.Client? client,
  })  : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _accessTokenProvider = accessTokenProvider,
        _rpc = rpc,
        _inputs = inputs,
        _pseudonyms = pseudonyms,
        _client = client ?? http.Client();

  final String _baseUrl;
  final Future<String?> Function() _accessTokenProvider;
  final BriefRpc _rpc;
  final ModelInputSource _inputs;
  final PseudonymService _pseudonyms;
  final http.Client _client;

  /// Writes the brief for [notebookId] (text, then audio, then the save).
  /// Errors are thrown; the caller logs them. A runtime rejection carries
  /// its status code, so the caller can tell one worth retrying.
  Future<void> requestBrief(String notebookId) async {
    // A brief whose text uses a stand-in that no longer stands for the same
    // person (retired, or forgotten meanwhile) is dropped unsaved and asked
    // for once more.
    try {
      await _requestOnce(notebookId);
    } on PseudonymResultStale {
      await _requestOnce(notebookId);
    }
  }

  Future<void> _requestOnce(String notebookId) async {
    if (_baseUrl.isEmpty) {
      throw StateError('The secure notebook runtime is not configured');
    }
    final accessToken = await _accessTokenProvider();
    if (accessToken == null || accessToken.isEmpty) {
      throw StateError('A signed-in session is required');
    }
    final url = Uri.parse(
      '$_baseUrl/v1/notebooks/${Uri.encodeComponent(notebookId)}/brief',
    );

    final input = await _inputs.brief(notebookId);
    if (!input.turns.any(
      (t) => t.speaker == 'user' && t.text.trim().isNotEmpty,
    )) {
      // As the runtime answers: nothing to open with.
      throw const SessionBriefException(
        'Nothing was said to write a brief from',
        statusCode: 422,
      );
    }
    final questions = [
      for (final q in input.questions)
        if (q.questions.isNotEmpty) q,
    ];

    // Every text the model reads, swapped with one version of the map.
    final extras = <String>[];
    int take(String value) {
      extras.add(value);
      return extras.length - 1;
    }

    final followUpAt = input.followUps.map(take).toList();
    final questionAt = [
      for (final q in questions)
        (name: take(q.name), questions: q.questions.map(take).toList()),
    ];
    final topAt = [for (final e in input.topEntities) take(e.name)];
    final previous = input.previous;
    final previousAt = previous == null
        ? null
        : (
            focus: previous.focus.map(take).toList(),
            thread: take(previous.openingThread),
          );

    await _pseudonyms.syncGraph(input.entities);
    final swapped = await _pseudonyms.swapTurns(
      [for (final t in input.turns) t.text],
      extras: extras,
    );
    // Nobody signed in: the map can't swap, so nothing is sent.
    if (swapped == null) throw StateError('A signed-in session is required');
    final out = swapped.extras;
    // A piece that couldn't be swapped safely is left out of a list (a turn
    // goes as "[omitted]"); everything is clamped to the runtime's limits.
    bool usable(int at) => out[at] != omittedText;
    String text(int at, int max) => clampText(out[at], max);

    final written = await _post(url, accessToken, {
      'version': 2,
      'turns': clampTurns(
        [
          for (var i = 0; i < input.turns.length; i++)
            (speaker: input.turns[i].speaker, text: swapped.turns[i]),
        ],
        spokenAt: [for (final t in input.turns) t.spokenAt],
      ),
      'previous': previousAt == null
          ? null
          : {
              'focus': [
                for (final at in previousAt.focus)
                  if (usable(at)) text(at, appInputLimits.focusText),
              ],
              'openingThread': usable(previousAt.thread)
                  ? text(previousAt.thread, appInputLimits.openingThread)
                  : '',
            },
      'followUps': [
        for (final at in followUpAt)
          if (usable(at)) text(at, appInputLimits.followUpText),
      ],
      'questions': [
        for (final at in questionAt)
          if (usable(at.name) && at.questions.any(usable))
            {
              'name': text(at.name, appInputLimits.entityName),
              'questions': [
                for (final q in at.questions)
                  if (usable(q)) text(q, appInputLimits.questionText),
              ],
            },
      ],
      'topEntities': [
        for (var i = 0; i < input.topEntities.length; i++)
          if (usable(topAt[i]))
            {
              'name': text(topAt[i], appInputLimits.entityName),
              'type': input.topEntities[i].type,
            },
      ],
      // Which words of the line the runtime writes are names, so the
      // speak step lets only those change (and only to the user's own
      // entities' names).
      'standIns': swapped.snapshot.standIns.take(500).toList(),
      'sourceRevision': input.revision,
    });
    if (written['status'] == 'unchanged') return;
    // A runtime from before v2 ignores the version: it wrote, spoke and saved
    // the brief itself and answers {"status": "ready"} with no brief.
    if (written['status'] == 'ready' && !written.containsKey('brief')) return;
    final brief = written['brief'];
    final token = written['speakToken'];
    if (written['status'] != 'ready' || brief is! Map || token is! String) {
      throw const FormatException('Invalid session-brief response');
    }

    // The stand-ins as they were when this request was swapped; throws
    // PseudonymResultStale if one no longer stands for the same person.
    final real = (await _pseudonyms.restore(swapped.snapshot, {
      'focus': [
        for (final item in (brief['focus'] as List? ?? const []))
          if (item is String) item,
      ],
      'openingThread': (brief['openingThread'] as String?) ?? '',
      'openingLine': ((brief['openingLine'] as String?) ?? '').trim(),
    }) as Map)
        .cast<String, dynamic>();

    final writtenRevision = written['sourceRevision'];
    if (writtenRevision is! int) {
      throw const FormatException('Invalid session-brief response');
    }

    // The runtime speaks only the line it wrote, its stand-ins replaced by
    // names from the user's own graph, with the token from the write; it
    // hands back the line it spoke (clamped to what the save accepts), and
    // that is the line saved.
    //
    // A line that can't be spoken (longer than the speak step takes once the
    // real names are back, or refused by its check, e.g. a name the graph
    // doesn't hold) still saves its text, with no audio: the next
    // conversation opens with the standard clip (SessionBrief.usable needs
    // audio) and the focus and thread carry forward. Nothing is lost and
    // OpeningPrep sees a success, so it doesn't retry.
    final restoredLine = real['openingLine'] as String;
    String? audio;
    var sampleRate = 24000;
    var revision = writtenRevision;
    if (restoredLine.length <= speakLineCap) {
      try {
        final spoken = await _post(url, accessToken, {
          'version': 2,
          'speak': {'openingLine': restoredLine, 'speakToken': token},
        });
        if (spoken['status'] == 'unchanged') return;
        final spokenAudio = spoken['audioBase64'];
        final spokenRate = spoken['sampleRate'];
        final line = spoken['openingLine'];
        final spokenRevision = spoken['sourceRevision'];
        if (spoken['status'] != 'ready' ||
            spokenAudio is! String ||
            spokenRate is! int ||
            line is! String ||
            spokenRevision is! int) {
          throw const FormatException('Invalid session-brief response');
        }
        audio = spokenAudio;
        sampleRate = spokenRate;
        revision = spokenRevision;
        real['openingLine'] = line;
      } on SessionBriefException catch (error) {
        if (error.statusCode != 403) rethrow;
      }
    }
    if (audio == null) {
      real['openingLine'] = restoredLine.length <= savedLineCap
          ? restoredLine
          : '${clampText(restoredLine, savedLineCap - 1).trimRight()}…';
    }

    // save_session_brief keeps every rule the runtime's save had: caps, a
    // revision that isn't newer is not saved, and a brief naming a forgotten
    // person is not saved ("unchanged").
    final saved = await _rpc('save_session_brief', {
      'p_notebook_id': notebookId,
      'p_source_revision': revision,
      'p_brief': real,
      // Null: no audio (see above).
      'p_audio_base64': audio,
      'p_sample_rate': sampleRate,
    });
    if (saved is Map &&
        (saved['status'] == 'saved' || saved['status'] == 'unchanged')) {
      return;
    }
    if (saved is Map && saved['code'] == 'notFound') {
      throw const SessionBriefException(
        'The notebook was not found',
        statusCode: 404,
      );
    }
    throw const FormatException('Invalid save_session_brief response');
  }

  Future<Map<String, dynamic>> _post(
    Uri url,
    String accessToken,
    Map<String, dynamic> body,
  ) async {
    final response = await _client.post(
      url,
      headers: {
        'accept': 'application/json',
        'authorization': 'Bearer $accessToken',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      throw SessionBriefException(
        'The notebook runtime could not write the session brief',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Invalid session-brief response');
    }
    return decoded.cast<String, dynamic>();
  }

  /// The sign-in lookup (`get_session_brief`).
  Future<SessionOpeningState> load() async {
    final result = await _rpc('get_session_brief');
    if (result is! Map) {
      throw const FormatException('Invalid get_session_brief response');
    }
    return SessionOpeningState.fromJson(result);
  }

  /// Marks the brief created at [createdAt] as played. The server matches
  /// the instant exactly, so it goes out in UTC with microseconds intact.
  Future<void> markPlayed(DateTime createdAt) async {
    await _rpc('mark_session_brief_played', {
      'p_created_at': createdAt.toUtc().toIso8601String(),
    });
  }
}
