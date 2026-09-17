import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../logic/turn_state.dart';
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

class TurnJournalCheckpoint {
  const TurnJournalCheckpoint({required this.turn, this.preparedCommit});

  final FinalizedTurn turn;
  final PreparedTurnCommit? preparedCommit;

  Map<String, dynamic> toJson() => {
        'turn': turn.toJson(),
        if (preparedCommit != null) 'preparedCommit': preparedCommit!.toJson(),
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
      );
}

/// Durable, notebook-scoped checkpoints for finalized turns.
///
/// Writes are serialized and replaced atomically so a process termination can
/// leave either the previous complete checkpoint or the next complete
/// checkpoint, never a partially written JSON document.
class TurnJournalService {
  TurnJournalService({TurnJournalDirectoryProvider? directoryProvider})
      : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory;

  static const int _version = 1;

  final TurnJournalDirectoryProvider _directoryProvider;
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
        checkpoints[index] = TurnJournalCheckpoint(
          turn: turn,
          preparedCommit: checkpoints[index].preparedCommit,
        );
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
      final checkpoint = TurnJournalCheckpoint(
        turn: turn,
        preparedCommit: preparedCommit,
      );
      if (index == -1) {
        checkpoints.add(checkpoint);
      } else {
        checkpoints[index] = checkpoint;
      }
      await _writeCheckpoints(turn.notebookId, checkpoints);
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

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<Directory> _journalDirectory() async {
    final root = await _directoryProvider();
    final directory = Directory('${root.path}/turn-journal-v$_version');
    await directory.create(recursive: true);
    return directory;
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
    await temporary.rename(file.path);
  }
}
