import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../security/file_protection.dart';

/// The native backup exclusion (a named function so it can be a default).
Future<void> lumenExcludeFromBackup(String path) => excludeFromBackup(path);

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
    this.owner,
  });

  final SharedKind kind;
  final DateTime at;
  final String notebookId;

  /// The request body as sent (a decoded JSON object), minus credentials.
  final Map<String, dynamic> body;

  /// The account that was signed in when the request was built. Entries of
  /// another account are never read or kept (M1).
  final String? owner;

  /// Whether this entry holds a real, unswapped name.
  bool get carriesRealNames => kind == SharedKind.briefSpeak;

  Map<String, dynamic> toJson() => {
        'kind': kind.wire,
        'at': at.toUtc().toIso8601String(),
        'notebookId': notebookId,
        'body': body,
        if (owner != null) 'owner': owner,
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
      owner: json['owner'] is String ? json['owner'] as String : null,
    );
  }
}

/// The signed-in user's id, or null when nobody is (or auth isn't up).
String? _signedInUserId() {
  try {
    return Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}

/// "What Lumen shared" (LM-57): an on-device log of each request sent to a
/// model, as it was sent (names already swapped, LM-56).
///
/// One file per notebook in the app support folder, protected with
/// `NSFileProtectionComplete` and left out of backups. It is never uploaded,
/// never part of an export, and never printed. Entries older than
/// [retention] are swept at launch and when a log is read; the file goes
/// with its session, and all of it goes on sign-out or when a person is
/// forgotten. A failure to log never fails the request being logged, and a
/// file that can't be protected and left out of backups is never written.
///
/// Deleting fails closed: a delete that can't finish is remembered (outside
/// the log's folder) and finished by the next [sweep], and nothing is read
/// before it is deleted, so a file that can't be opened (the phone is
/// locked) still goes.
class SharedLog {
  /// The one instance the app uses, so every caller shares one queue.
  static final SharedLog instance = SharedLog(ownerId: _signedInUserId);

  SharedLog({
    Future<Directory> Function()? directoryProvider,
    FileProtector? protect,
    Future<void> Function(String path)? excludeFromBackup,
    DateTime Function()? now,
    String? Function()? ownerId,
    this.retention = const Duration(days: 7),
    this.maxBytes = 256 * 1024,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory,
        _protect = protect ?? protectFileStrict,
        _exclude = excludeFromBackup ?? lumenExcludeFromBackup,
        _now = now ?? DateTime.now,
        _ownerId = ownerId;

  static const int _version = 1;
  static const _pendingName = 'shared-log-pending';

  final Future<Directory> Function() _directoryProvider;

  /// Must throw when it can't protect the file: the write is then dropped.
  final FileProtector _protect;
  final Future<void> Function(String path) _exclude;
  final DateTime Function() _now;

  /// The signed-in user. When set, an entry carries its owner and only the
  /// current user's are read, kept or written; a request built by one
  /// account that lands after a switch is refused. Null: no scoping.
  final String? Function()? _ownerId;
  final Duration retention;

  /// A file is trimmed from its oldest end to stay under this (the newest
  /// entry always stays).
  final int maxBytes;
  Future<void> _tail = Future<void>.value();

  /// Sessions deleted in this run: a request still being recorded for one
  /// must not bring its file back.
  final Set<String> _deleted = {};

  /// A person was forgotten in this run: no speak line (it carries a real
  /// name) is recorded for the rest of it.
  bool _personForgotten = false;

  /// Signed out in this run: nothing is recorded until [resume] (the next
  /// sign-in), so a request of the old account can't land after the wipe.
  bool _signedOut = false;

  /// Records are accepted again (a sign-in), once a wipe still running from
  /// the sign-out has finished: a late record of the last account can never
  /// land in the next one's log.
  Future<void> resume() async {
    await _tail;
    _signedOut = false;
  }

  /// Records [body] (the object the request was built from) for
  /// [notebookId]. Call it at the one place the request is built, with the
  /// exact map that is then encoded and sent. Never throws.
  Future<void> record(
    String notebookId,
    SharedKind kind,
    Map<String, dynamic> body,
  ) async {
    final ownerOf = _ownerId;
    final owner = ownerOf?.call();
    bool refused() =>
        _signedOut ||
        (ownerOf != null && (owner == null || ownerOf() != owner)) ||
        _deleted.contains(notebookId) ||
        (_personForgotten && kind == SharedKind.briefSpeak);
    if (refused()) return;
    try {
      // A round trip through JSON: the entry holds what was encoded, and
      // later changes to [body] cannot reach it.
      final copy =
          (jsonDecode(jsonEncode(body)) as Map).cast<String, dynamic>();
      await _serialized(() async {
        if (refused()) return;
        final file = await _file(notebookId);
        // A file that can't be read (the phone is locked) is left as it is:
        // writing now would replace the history with one entry.
        final entries = await _load(file, notebookId);
        entries.add(SharedRequest(
          kind: kind,
          at: _now(),
          notebookId: notebookId,
          body: copy,
          owner: owner,
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
        // A delete that failed is finished first; if it can't be, nothing
        // is shown.
        if (!await _retryPending()) return const <SharedRequest>[];
        final file = await _file(notebookId);
        final fresh = await _freshOf(file, notebookId);
        return (fresh ?? const <SharedRequest>[]).reversed.toList();
      });

  /// Every session's entries, newest first.
  Future<List<SharedRequest>> readAll() => _serialized(() async {
        if (!await _retryPending()) return const <SharedRequest>[];
        final all = <SharedRequest>[];
        for (final file in await _files()) {
          all.addAll(await _freshOf(file, _idOf(file)) ?? const []);
        }
        all.sort((a, b) => b.at.compareTo(a.at));
        return all;
      });

  /// Finishes any delete that failed earlier, removes leftover temp files,
  /// and drops what is older than [retention] from every file (app launch).
  Future<void> sweep() => _serialized(() async {
        await _finishPending();
        for (final temp in await _temps()) {
          await temp.delete();
        }
        for (final file in await _files()) {
          // A file that isn't text can never be shown: it goes.
          await _freshOf(file, _idOf(file), deleteCorrupt: true);
        }
      });

  /// The session was deleted.
  Future<void> forgetNotebook(String notebookId) {
    // At once, so a request still being recorded can't bring it back.
    _deleted.add(notebookId);
    return _serialized(() async {
      await _markPending(notebook: notebookId);
      await _deleteNotebook(notebookId);
      await _clearPending(notebook: notebookId);
    });
  }

  /// Sign-out: nothing is left for the next account.
  Future<void> clearAll() {
    _signedOut = true;
    return _serialized(_wipe);
  }

  /// Someone was forgotten (LM-49). The speak request's line may carry their
  /// real name, and a name the swap missed could be in any other entry, so
  /// the whole log goes, for every session. Nothing is opened first.
  Future<void> forgetPerson() {
    _personForgotten = true;
    return _serialized(_wipe);
  }

  Future<void> _wipe() async {
    await _markPending(all: true);
    final directory = await _logDirectory();
    await for (final entity in directory.list()) {
      if (entity is File) await entity.delete();
    }
    await _clearPending(all: true);
  }

  Future<void> _deleteNotebook(String notebookId) async {
    final file = await _file(notebookId);
    for (final f in [file, File('${file.path}.tmp')]) {
      if (await f.exists()) await f.delete();
    }
  }

  /// A deletion that didn't finish is kept outside the log's folder, so the
  /// next launch can finish it.
  Future<File> _pendingFile() async =>
      File('${(await _directoryProvider()).path}/$_pendingName');

  /// What is pending. A pending file that exists but can't be read (the
  /// phone is locked, or it is damaged) counts as "delete everything".
  Future<Map<String, dynamic>> _readPending() async {
    final File file;
    try {
      file = await _pendingFile();
      if (!await file.exists()) return {};
    } catch (_) {
      return {};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return {'all': true};
  }

  /// Written protected and left out of backups; if either fails the file
  /// stays anyway, so the retry still happens (it holds only ids).
  Future<void> _writePending(Map<String, dynamic> pending) async {
    final file = await _pendingFile();
    await file.writeAsString(jsonEncode(pending));
    try {
      await _protect(file.path, FileProtectionLevel.complete);
      await _exclude(file.path);
    } catch (_) {}
  }

  Future<void> _markPending({String? notebook, bool all = false}) async {
    try {
      final pending = await _readPending();
      final notebooks = {
        ...((pending['notebooks'] as List?) ?? const []).cast<String>(),
        if (notebook != null) notebook,
      };
      await _writePending({
        'all': all || pending['all'] == true,
        'notebooks': notebooks.toList(),
      });
    } catch (_) {
      // Best effort: the delete itself still runs.
    }
  }

  Future<void> _clearPending({String? notebook, bool all = false}) async {
    try {
      final file = await _pendingFile();
      if (all) {
        if (await file.exists()) await file.delete();
        return;
      }
      final pending = await _readPending();
      final notebooks = ((pending['notebooks'] as List?) ?? const [])
          .cast<String>()
          .where((id) => id != notebook)
          .toList();
      if (notebooks.isEmpty && pending['all'] != true) {
        if (await file.exists()) await file.delete();
      } else {
        await _writePending({
          'all': pending['all'] == true,
          'notebooks': notebooks,
        });
      }
    } catch (_) {}
  }

  Future<void> _finishPending() async {
    final pending = await _readPending();
    if (pending['all'] == true) {
      await _wipe();
      return;
    }
    for (final id
        in ((pending['notebooks'] as List?) ?? const []).cast<String>()) {
      await _deleteNotebook(id);
      await _clearPending(notebook: id);
    }
  }

  /// Finishes a delete that failed earlier. False when it can't be.
  Future<bool> _retryPending() async {
    try {
      await _finishPending();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// [file]'s entries within [retention], rewritten if some were older. Null
  /// when the file can't be read now.
  Future<List<SharedRequest>?> _freshOf(
    File file,
    String id, {
    bool deleteCorrupt = false,
  }) async {
    try {
      final entries = await _load(file, id);
      final fresh = _fresh(entries);
      if (fresh.length != entries.length) await _write(file, fresh);
      return fresh;
    } on FormatException {
      // Not text (damaged): never shown.
      if (deleteCorrupt) await file.delete();
      return null;
    } on FileSystemException {
      return null;
    }
  }

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

  Directory? _directory;
  bool _directorySecured = false;

  Future<Directory> _logDirectory() async {
    final existing = _directory;
    if (existing != null) return existing;
    final root = await _directoryProvider();
    final directory = Directory('${root.path}/shared-log-v$_version');
    await directory.create(recursive: true);
    return _directory = directory;
  }

  /// Before anything is written: the folder (and so what is in it) is left
  /// out of backups. A failure drops the write.
  Future<void> _secureDirectory() async {
    if (_directorySecured) return;
    await _exclude((await _logDirectory()).path);
    _directorySecured = true;
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

  Future<List<File>> _temps() async {
    final directory = await _logDirectory();
    return [
      await for (final f in directory.list())
        if (f is File && f.path.endsWith('.tmp')) f,
    ];
  }

  String _idOf(File file) {
    final name = file.uri.pathSegments.last;
    return Uri.decodeComponent(name.substring(0, name.length - '.json'.length));
  }

  /// A missing file is empty, and so is one that isn't a log (it is
  /// overwritten by the next entry). A file that can't be read throws.
  Future<List<SharedRequest>> _load(File file, String notebookId) async {
    if (!await file.exists()) return <SharedRequest>[];
    // Bytes first: a read that fails is an I/O error (FileSystemException);
    // bytes that aren't text are a FormatException.
    final text = utf8.decode(await file.readAsBytes());
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded['entries'] is! List) {
        return <SharedRequest>[];
      }
      return [
        for (final raw in decoded['entries'] as List)
          if (SharedRequest.tryParse(raw) case final e?
              when e.notebookId == notebookId && _isMine(e))
            e,
      ];
    } catch (_) {
      return <SharedRequest>[];
    }
  }

  bool _isMine(SharedRequest entry) {
    final ownerId = _ownerId;
    if (ownerId == null) return true;
    final current = ownerId();
    return current != null && entry.owner == current;
  }

  /// Through a temp file that is protected and left out of backups before it
  /// takes the file's place; whatever goes wrong, no temp file is left, and
  /// no unprotected file is.
  Future<void> _write(File file, List<SharedRequest> entries) async {
    final temp = File('${file.path}.tmp');
    if (entries.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    try {
      await _secureDirectory();
      await temp.writeAsString(_encode(entries), flush: true);
      await _protect(temp.path, FileProtectionLevel.complete);
      await _exclude(temp.path);
      await temp.rename(file.path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }
}
