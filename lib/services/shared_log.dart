import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../security/file_protection.dart';

/// Which model-bound request an entry records (LM-57).
enum SharedKind {
  extraction('Extraction', 'extraction'),
  card('Closing card', 'card'),
  draft('Card draft', 'draft'),
  briefWrite('Brief: writing', 'briefWrite'),

  /// The one request that carries a real name: the opening line goes to the
  /// voice as the user said it, so it is read aloud right.
  briefSpeak('Brief: speaking', 'briefSpeak');

  const SharedKind(this.label, this.wire);
  final String label;
  final String wire;

  static SharedKind? fromWire(Object? wire) {
    for (final kind in values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// One request as it left the phone.
class SharedRequest {
  const SharedRequest({
    required this.kind,
    required this.at,
    required this.notebookId,
    required this.body,
  });

  final SharedKind kind;
  final DateTime at;
  final String notebookId;

  /// The request body as sent (a decoded JSON object), minus credentials.
  final Map<String, dynamic> body;

  /// Whether this entry holds a real, unswapped name.
  bool get carriesRealNames => kind == SharedKind.briefSpeak;

  Map<String, dynamic> toJson() => {
        'kind': kind.wire,
        'at': at.toUtc().toIso8601String(),
        'notebookId': notebookId,
        'body': body,
      };

  static SharedRequest? tryParse(Object? json) {
    if (json is! Map) return null;
    final kind = SharedKind.fromWire(json['kind']);
    final at = DateTime.tryParse('${json['at']}');
    final id = json['notebookId'];
    final body = json['body'];
    if (kind == null || at == null || id is! String || body is! Map) {
      return null;
    }
    return SharedRequest(
      kind: kind,
      at: at,
      notebookId: id,
      body: body.cast<String, dynamic>(),
    );
  }
}

/// "What Lumen shared" (LM-57): an on-device log of each request sent to a
/// model, as it was sent (names already swapped, LM-56).
///
/// One file per notebook in the app support folder, protected with
/// `NSFileProtectionComplete`. It is never uploaded, never part of an export,
/// and never printed. Entries older than [retention] are swept at launch and
/// when a log is read; the file goes with its session, and all of it goes on
/// sign-out. A failure to log never fails the request being logged.
class SharedLog {
  SharedLog({
    Future<Directory> Function()? directoryProvider,
    FileProtector? protect,
    DateTime Function()? now,
    this.retention = const Duration(days: 7),
    this.maxBytes = 256 * 1024,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory,
        _protect = protect ?? protectFile,
        _now = now ?? DateTime.now;

  static const int _version = 1;

  final Future<Directory> Function() _directoryProvider;
  final FileProtector _protect;
  final DateTime Function() _now;
  final Duration retention;

  /// A file is trimmed from its oldest end to stay under this (the newest
  /// entry always stays).
  final int maxBytes;
  Future<void> _tail = Future<void>.value();

  /// Records [body] (the object the request was built from) for
  /// [notebookId]. Call it at the one place the request is built, with the
  /// exact map that is then encoded and sent. Never throws.
  Future<void> record(
    String notebookId,
    SharedKind kind,
    Map<String, dynamic> body,
  ) async {
    try {
      // A round trip through JSON: the entry holds what was encoded, and
      // later changes to [body] cannot reach it.
      final copy =
          (jsonDecode(jsonEncode(body)) as Map).cast<String, dynamic>();
      await _serialized(() async {
        final file = await _file(notebookId);
        final entries = await _load(file, notebookId);
        entries.add(SharedRequest(
          kind: kind,
          at: _now(),
          notebookId: notebookId,
          body: copy,
        ));
        await _write(file, _trimmed(_fresh(entries)));
      });
    } catch (_) {
      // Logging is a courtesy to the user; the request goes regardless. The
      // error is dropped: it could quote what was said.
    }
  }

  /// [notebookId]'s entries, newest first (older than [retention] swept).
  Future<List<SharedRequest>> read(String notebookId) => _serialized(() async {
        final file = await _file(notebookId);
        final entries = await _load(file, notebookId);
        final fresh = _fresh(entries);
        if (fresh.length != entries.length) await _write(file, fresh);
        return fresh.reversed.toList();
      });

  /// Every session's entries, newest first.
  Future<List<SharedRequest>> readAll() => _serialized(() async {
        final all = <SharedRequest>[];
        for (final file in await _files()) {
          final id = _idOf(file);
          final entries = await _load(file, id);
          final fresh = _fresh(entries);
          if (fresh.length != entries.length) await _write(file, fresh);
          all.addAll(fresh);
        }
        all.sort((a, b) => b.at.compareTo(a.at));
        return all;
      });

  /// Drops what is older than [retention] from every file (app launch).
  Future<void> sweep() => _serialized(() async {
        for (final file in await _files()) {
          final entries = await _load(file, _idOf(file));
          final fresh = _fresh(entries);
          if (fresh.length != entries.length) await _write(file, fresh);
        }
      });

  /// The session was deleted.
  Future<void> forgetNotebook(String notebookId) => _serialized(() async {
        final file = await _file(notebookId);
        if (await file.exists()) await file.delete();
      });

  /// Sign-out: nothing is left for the next account.
  Future<void> clearAll() => _serialized(() async {
        for (final file in await _files()) {
          await file.delete();
        }
      });

  /// Someone was forgotten (LM-49). The log holds swapped text, except the
  /// speak request, whose line may carry that person's real name. It has no
  /// way to tell whose name a line holds, so every speak entry goes, for
  /// every session.
  Future<void> forgetSpeakEntries() => _serialized(() async {
        for (final file in await _files()) {
          final entries = await _load(file, _idOf(file));
          final kept = [
            for (final e in entries)
              if (!e.carriesRealNames) e,
          ];
          if (kept.length == entries.length) continue;
          if (kept.isEmpty) {
            await file.delete();
          } else {
            await _write(file, kept);
          }
        }
      });

  List<SharedRequest> _fresh(List<SharedRequest> entries) {
    final cutoff = _now().subtract(retention);
    return [
      for (final e in entries)
        if (!e.at.isBefore(cutoff)) e,
    ];
  }

  List<SharedRequest> _trimmed(List<SharedRequest> entries) {
    var kept = entries;
    while (kept.length > 1 && _encode(kept).length > maxBytes) {
      kept = kept.sublist(1);
    }
    return kept;
  }

  String _encode(List<SharedRequest> entries) => jsonEncode({
        'version': _version,
        'entries': [for (final e in entries) e.toJson()],
      });

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Directory>? _directory;

  Future<Directory> _logDirectory() {
    return _directory ??= () async {
      final root = await _directoryProvider();
      final directory = Directory('${root.path}/shared-log-v$_version');
      await directory.create(recursive: true);
      return directory;
    }()
        .catchError((Object error) {
      _directory = null;
      throw error;
    });
  }

  Future<File> _file(String notebookId) async {
    final directory = await _logDirectory();
    return File('${directory.path}/${Uri.encodeComponent(notebookId)}.json');
  }

  Future<List<File>> _files() async {
    final directory = await _logDirectory();
    return [
      await for (final f in directory.list())
        if (f is File && f.path.endsWith('.json')) f,
    ];
  }

  String _idOf(File file) {
    final name = file.uri.pathSegments.last;
    return Uri.decodeComponent(name.substring(0, name.length - '.json'.length));
  }

  /// A damaged or foreign file reads as empty (and is overwritten by the
  /// next entry) rather than failing the caller.
  Future<List<SharedRequest>> _load(File file, String notebookId) async {
    try {
      if (!await file.exists()) return <SharedRequest>[];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['entries'] is! List) {
        return <SharedRequest>[];
      }
      return [
        for (final raw in decoded['entries'] as List)
          if (SharedRequest.tryParse(raw) case final e?
              when e.notebookId == notebookId)
            e,
      ];
    } catch (_) {
      return <SharedRequest>[];
    }
  }

  Future<void> _write(File file, List<SharedRequest> entries) async {
    if (entries.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(_encode(entries), flush: true);
    await _protect(temp.path, FileProtectionLevel.complete);
    await temp.rename(file.path);
  }
}
