import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Leaving a notebook ended after its live transport closed: its last
/// writes didn't drain, or it couldn't be marked ended. The notebook is
/// still open in the journal; [retry] leaves it again (and tracks the new
/// attempt in [LeavingNotebooks]).
class LeaveIncomplete implements Exception {
  const LeaveIncomplete({required this.retry, this.message});

  final Future<void> Function() retry;
  final String? message;

  @override
  String toString() => 'LeaveIncomplete: ${message ?? 'not finished'}';
}

/// Notebooks being left in the background. Leaving for the closing card
/// navigates as soon as the live transport is closed; draining the last
/// writes, marking the notebook ended and asking for its final card go on
/// here. The card screen waits on [pending] before asking for the final
/// card, so it is never written from a revision the drain is about to move.
class LeavingNotebooks {
  final _leaving = <String, Future<void>>{};

  /// The leave of [notebookId] still running, or one that failed with
  /// [LeaveIncomplete]; null once it finished (or none was tracked).
  Future<void>? pending(String notebookId) => _leaving[notebookId];

  /// Tracks [leaving] for [notebookId], replacing any earlier attempt. It is
  /// dropped once it succeeds; a failure stays until the notebook is left
  /// again, so a card screen that arrives late still sees it.
  void track(String notebookId, Future<void> leaving) {
    _leaving[notebookId] = leaving;
    leaving.then(
      (_) {
        if (identical(_leaving[notebookId], leaving)) {
          _leaving.remove(notebookId);
        }
      },
      // Handled where it's awaited; this only keeps it from going unhandled.
      onError: (Object _) {},
    );
  }
}

final leavingNotebooksProvider = Provider<LeavingNotebooks>(
  (ref) => LeavingNotebooks(),
);
