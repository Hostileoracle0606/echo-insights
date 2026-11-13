import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'journal_provider.dart';
import 'supabase_provider.dart';

enum EraseStatus { running, done, paused }

/// Where the opt-in transcript erase is (R35). Counts only: no names.
@immutable
class EraseRun {
  const EraseRun({
    required this.jobId,
    required this.status,
    this.total = 0,
    this.remaining,
  });

  final String jobId;
  final EraseStatus status;

  /// Rows rewritten so far.
  final int total;

  /// Rows the server has still to check; null before the first step.
  final int? remaining;

  EraseRun copyWith({EraseStatus? status, int? total, int? remaining}) =>
      EraseRun(
        jobId: jobId,
        status: status ?? this.status,
        total: total ?? this.total,
        remaining: remaining ?? this.remaining,
      );
}

/// What runs once an erase finishes: the open notebook reads its saved turns
/// again, so its transcript shows the words as now stored.
final eraseFinishedHookProvider = Provider<Future<void> Function()>(
  (ref) => () => ref.read(journalProvider.notifier).reloadSavedTurns(),
);

final transcriptEraseProvider =
    NotifierProvider<TranscriptEraseNotifier, EraseRun?>(
        TranscriptEraseNotifier.new);

/// Runs a queued erase as bounded server steps after the forget has
/// committed. A step that fails pauses it; the job stays on the server and
/// [resumePending] picks it up on the next launch.
class TranscriptEraseNotifier extends Notifier<EraseRun?> {
  static const batch = 300;
  final _running = <String, Future<bool>>{};

  @override
  EraseRun? build() => null;

  /// Steps job [jobId] to the end. True when it finished, false if paused.
  Future<bool> run(String jobId) => _running[jobId] ??= _run(jobId)
          // A block body: returning the removed future would wait on itself.
          .whenComplete(() {
        _running.remove(jobId);
      });

  Future<bool> _run(String jobId) async {
    final service = ref.read(memoryControlServiceProvider);
    state = EraseRun(jobId: jobId, status: EraseStatus.running);
    try {
      while (true) {
        final step = await service.eraseStep(jobId, batch: batch);
        state = state!.copyWith(
          total: step.total,
          remaining: step.finished ? 0 : step.remaining,
          status: step.finished ? EraseStatus.done : EraseStatus.running,
        );
        if (step.finished) break;
      }
    } catch (error) {
      // No detail: errors never carry what was erased.
      debugPrint('Erase paused: ${error.runtimeType}');
      state = state!.copyWith(status: EraseStatus.paused);
      return false;
    }
    try {
      await ref.read(eraseFinishedHookProvider)();
    } catch (error) {
      debugPrint('Reload after erase failed: ${error.runtimeType}');
    }
    return true;
  }

  /// Every erase the server still holds for this account, one after another.
  /// Never throws.
  Future<void> resumePending() async {
    try {
      final jobs = await ref.read(memoryControlServiceProvider).pendingErases();
      for (final job in jobs) {
        if (!await run(job)) return;
      }
    } catch (error) {
      debugPrint('Pending erases not resumed: ${error.runtimeType}');
    }
  }
}

/// [TranscriptEraseNotifier.resumePending] from places that must never fail
/// because of it.
Future<void> runEraseResume(TranscriptEraseNotifier Function() erase) async {
  try {
    await erase().resumePending();
  } catch (error) {
    debugPrint('Erase resume not run: ${error.runtimeType}');
  }
}
