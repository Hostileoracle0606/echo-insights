import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../logic/turn_state.dart';
import '../security/file_protection.dart';
import 'notebook_commit_service.dart' as commit_service;

typedef TurnJournalDirectoryProvider = Future<Directory> Function();

class PreparedTurnCommit {
  const PreparedTurnCommit({
    required this.expectedRevision,
    required this.change,
    required this.entryId,
  });

  final int expectedRevision;
  final commit_service.ApplyTurnChange change;
  final String entryId;

  Map<String, dynamic> toJson() => {
        'expectedRevision': expectedRevision,
        'change': change.toJson(),
        'entryId': entryId,
      };

  factory PreparedTurnCommit.fromJson(Map<String, dynamic> json) =>
      PreparedTurnCommit(
        expectedRevision: (json['expectedRevision'] as num).toInt(),
        change: commit_service.ApplyTurnChange.fromJson(
          (json['change'] as Map).cast<String, dynamic>(),
        ),
        entryId: json['entryId'] as String,
      );
}

/// A step of a journalled turn whose refusals are counted.
enum TurnStepKind { extract, commit }

class TurnJournalCheckpoint {
  const TurnJournalCheckpoint({
    required this.turn,
    this.preparedCommit,
    this.extractAttempts = 0,
    this.commitAttempts = 0,
  });

  final FinalizedTurn turn;
  final PreparedTurnCommit? preparedCommit;

  /// Refused extraction attempts so far (counts only), so catch-up can stop
  /// asking after a bound instead of blocking the notebook forever.
  final int extractAttempts;

  /// Refused (`commitFailed`) commit attempts so far.
  final int commitAttempts;

  int attempts(TurnStepKind kind) => switch (kind) {
        TurnStepKind.extract => extractAttempts,
        TurnStepKind.commit => commitAttempts,
      };

  TurnJournalCheckpoint _with({
    FinalizedTurn? turn,
    PreparedTurnCommit? preparedCommit,
    int? extractAttempts,
    int? commitAttempts,
  }) =>
      TurnJournalCheckpoint(
        turn: turn ?? this.turn,
        preparedCommit: preparedCommit ?? this.preparedCommit,
        extractAttempts: extractAttempts ?? this.extractAttempts,
        commitAttempts: commitAttempts ?? this.commitAttempts,
      );

  Map<String, dynamic> toJson() => {
        'turn': turn.toJson(),
        if (preparedCommit != null) 'preparedCommit': preparedCommit!.toJson(),
        if (extractAttempts > 0) 'extractAttempts': extractAttempts,
        if (commitAttempts > 0) 'commitAttempts': commitAttempts,
      };

  factory TurnJournalCheckpoint.fromJson(Map<String, dynamic> json) =>
      TurnJournalCheckpoint(
        turn: FinalizedTurn.fromJson(
          (json['turn'] as Map).cast<String, dynamic>(),
        ),
        preparedCommit: json['preparedCommit'] is Map
            ? PreparedTurnCommit.fromJson(
                (json['preparedCommit'] as Map).cast<String, dynamic>(),
              )
            : null,
        extractAttempts: (json['extractAttempts'] as num?)?.toInt() ?? 0,
        commitAttempts: (json['commitAttempts'] as num?)?.toInt() ?? 0,
      );
}

/// Durable, notebook-scoped checkpoints for finalized turns.
///
/// Writes are serialized and replaced atomically so a process termination can
/// leave either the previous complete checkpoint or the next complete
/// checkpoint, never a partially written JSON document.
class TurnJournalService {
  TurnJournalService({
    TurnJournalDirectoryProvider? directoryProvider,
    FileProtector? protect,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory,
        _protect = protect ?? protectFile;

  static const int _version = 1;

  final TurnJournalDirectoryProvider _directoryProvider;
  final FileProtector _protect;
  Future<void> _tail = Future<void>.value();

  Future<List<TurnJournalCheckpoint>> loadCheckpoints(String notebookId) {
    return _serialized(() => _readCheckpoints(notebookId));
  }

  Future<List<FinalizedTurn>> loadTurns(String notebookId) async {
    final checkpoints = await loadCheckpoints(notebookId);
    return checkpoints
        .map((checkpoint) => checkpoint.turn)
        .toList(growable: false);
  }

  Future<void> persistTurn(FinalizedTurn turn) {
    return _serialized(() async {
      final checkpoints = await _readCheckpoints(turn.notebookId);
      final index = checkpoints.indexWhere(
        (checkpoint) => checkpoint.turn.turnId == turn.turnId,
      );
      if (index == -1) {
        checkpoints.add(TurnJournalCheckpoint(turn: turn));
      } else {
        checkpoints[index] = checkpoints[index]._with(turn: turn);
      }
      await _writeCheckpoints(turn.notebookId, checkpoints);
    });
  }

  Future<void> persistPreparedCommit({
    required FinalizedTurn turn,
    required PreparedTurnCommit preparedCommit,
  }) {
    return _serialized(() async {
      final checkpoints = await _readCheckpoints(turn.notebookId);
      final index = checkpoints.indexWhere(
        (checkpoint) => checkpoint.turn.turnId == turn.turnId,
      );
      if (index == -1) {
        checkpoints.add(TurnJournalCheckpoint(
          turn: turn,
          preparedCommit: preparedCommit,
        ));
      } else {
        checkpoints[index] = checkpoints[index]._with(
          turn: turn,
          preparedCommit: preparedCommit,
        );
      }
      await _writeCheckpoints(turn.notebookId, checkpoints);
    });
  }

  /// Adds one refused [kind] attempt to the turn's checkpoint and returns
  /// the new count; 0 when the turn is no longer journalled.
  Future<int> countAttempt({
    required String notebookId,
    required String turnId,
    required TurnStepKind kind,
  }) {
    return _serialized(() async {
      final checkpoints = await _readCheckpoints(notebookId);
      final index = checkpoints.indexWhere(
        (checkpoint) => checkpoint.turn.turnId == turnId,
      );
      if (index == -1) return 0;
      final current = checkpoints[index];
      final count = current.attempts(kind) + 1;
      checkpoints[index] = switch (kind) {
        TurnStepKind.extract => current._with(extractAttempts: count),
        TurnStepKind.commit => current._with(commitAttempts: count),
      };
      await _writeCheckpoints(notebookId, checkpoints);
      return count;
    });
  }

  Future<void> forgetTurn({
    required String notebookId,
    required String turnId,
  }) {
    return _serialized(() async {
      final checkpoints = await _readCheckpoints(notebookId);
      checkpoints.removeWhere(
        (checkpoint) => checkpoint.turn.turnId == turnId,
      );
      final file = await _journalFile(notebookId);
      if (checkpoints.isEmpty) {
        if (await file.exists()) await file.delete();
        return;
      }
      await _writeCheckpoints(notebookId, checkpoints);
    });
  }

  /// Notebook ids holding at least one journalled turn, newest turn first.
  ///
  /// The journal only ever holds turns not yet committed: a confirmed commit
  /// or a refused one removes its checkpoint ([forgetTurn]), and a
  /// checkpoint left at [DurableStage.committed] or [DurableStage.failed] is
  /// ignored on read. So every id here has work to finish. A file that
  /// cannot be read is skipped: it must not stop the others being found.
  Future<List<String>> listNotebookIdsWithTurns() {
    return _serialized(() async {
      final directory = await _journalDirectory();
      final newest = <String, DateTime>{};
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.json')) continue;
        final String notebookId;
        try {
          notebookId = Uri.decodeComponent(
            name.substring(0, name.length - '.json'.length),
          );
        } on ArgumentError {
          continue;
        }
        final List<TurnJournalCheckpoint> checkpoints;
        try {
          checkpoints = await _readCheckpoints(notebookId);
        } on Object {
          continue;
        }
        for (final checkpoint in checkpoints) {
          final at = DateTime.tryParse(checkpoint.turn.finalizedAt) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
          final seen = newest[notebookId];
          if (seen == null || at.isAfter(seen)) newest[notebookId] = at;
        }
      }
      final ids = newest.keys.toList()
        ..sort((a, b) {
          final byTime = newest[b]!.compareTo(newest[a]!);
          return byTime != 0 ? byTime : a.compareTo(b);
        });
      return ids;
    });
  }

  /// Everything held for [notebookId]: the session was deleted.
  Future<void> forgetNotebook(String notebookId) {
    return _serialized(() async {
      final file = await _journalFile(notebookId);
      if (await file.exists()) await file.delete();
    });
  }

  /// Account deletion clears this phone's durable turn checkpoints, including
  /// any temporary file left by an interrupted write.
  Future<void> forgetAll() {
    return _serialized(() async {
      final directory = await _journalDirectory();
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } finally {
        _directory = null;
      }
    });
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  /// Finds the journal folder ahead of the first notebook open. The first
  /// file-system access after launch costs over a second on the simulator,
  /// which otherwise lands between tapping New notebook and the greeting.
  Future<void> warmUp() async {
    try {
      await _journalDirectory();
    } catch (_) {
      // The next read looks again and reports a real failure itself.
    }
  }

  Future<Directory>? _directory;

  /// The folder is looked up once; a failed lookup is retried next time.
  Future<Directory> _journalDirectory() {
    return _directory ??= () async {
      final root = await _directoryProvider();
      final directory = Directory('${root.path}/turn-journal-v$_version');
      await directory.create(recursive: true);
      // New files here start in the same class, so a checkpoint created
      // just after the phone locks can still be written.
      await _protect(directory.path, FileProtectionLevel.completeUnlessOpen);
      return directory;
    }()
        .catchError((Object error) {
      _directory = null;
      throw error;
    });
  }

  Future<File> _journalFile(String notebookId) async {
    final directory = await _journalDirectory();
    return File('${directory.path}/${Uri.encodeComponent(notebookId)}.json');
  }

  Future<List<TurnJournalCheckpoint>> _readCheckpoints(
    String notebookId,
  ) async {
    final file = await _journalFile(notebookId);
    if (!await file.exists()) return <TurnJournalCheckpoint>[];

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != _version ||
        decoded['notebookId'] != notebookId ||
        decoded['checkpoints'] is! List) {
      throw const FormatException('Invalid durable turn journal');
    }

    return (decoded['checkpoints'] as List)
        .map((value) {
          if (value is! Map) {
            throw const FormatException('Invalid durable turn checkpoint');
          }
          final checkpoint = TurnJournalCheckpoint.fromJson(
            value.cast<String, dynamic>(),
          );
          if (checkpoint.turn.notebookId != notebookId) {
            throw const FormatException(
              'Turn checkpoint belongs to another notebook',
            );
          }
          return checkpoint;
        })
        .where((checkpoint) =>
            checkpoint.turn.stage != DurableStage.committed &&
            checkpoint.turn.stage != DurableStage.failed)
        .toList(growable: true);
  }

  Future<void> _writeCheckpoints(
    String notebookId,
    List<TurnJournalCheckpoint> checkpoints,
  ) async {
    final file = await _journalFile(notebookId);
    final temporary = File('${file.path}.tmp');
    final document = <String, dynamic>{
      'version': _version,
      'notebookId': notebookId,
      'checkpoints': checkpoints
          .map((checkpoint) => checkpoint.toJson())
          .toList(growable: false),
    };

    await temporary.writeAsString(jsonEncode(document), flush: true);
    // The class travels with the file through the rename.
    await _protect(temporary.path, FileProtectionLevel.completeUnlessOpen);
    await temporary.rename(file.path);
  }
}
