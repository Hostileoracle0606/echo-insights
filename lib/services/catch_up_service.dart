import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'headless_turn_finisher.dart' show NotebookFinishResult;
import 'session_brief_service.dart' show SessionBriefException;
import 'unfinished_work_service.dart';

/// One unit of launch-time catch-up (LM-103). Plain values keyed by ids and
/// revisions, never by text, so a plan can be logged and compared.
sealed class CatchUpStep {
  const CatchUpStep();

  /// The notebook the step belongs to; null for account-wide work (erase).
  String? get notebookId;
}

/// Commit every journalled turn of [notebookId], in journal order, without
/// opening it (see `HeadlessTurnFinisher.finishNotebook`).
class FinishTurnsStep extends CatchUpStep {
  const FinishTurnsStep({required this.notebookId});

  @override
  final String notebookId;

  @override
  bool operator ==(Object other) =>
      other is FinishTurnsStep && other.notebookId == notebookId;

  @override
  int get hashCode => Object.hash(FinishTurnsStep, notebookId);

  @override
  String toString() => 'FinishTurnsStep($notebookId)';
}

/// Make the card for [notebookId] at [revision] (status first: a card
/// already present at that revision means nothing to do).
class CardStep extends CatchUpStep {
  const CardStep({
    required this.notebookId,
    required this.revision,
    this.cardRevision,
    this.draft = false,
  });

  @override
  final String notebookId;
  final int revision;
  final int? cardRevision;
  final bool draft;

  @override
  bool operator ==(Object other) =>
      other is CardStep &&
      other.notebookId == notebookId &&
      other.revision == revision &&
      other.cardRevision == cardRevision &&
      other.draft == draft;

  @override
  int get hashCode =>
      Object.hash(CardStep, notebookId, revision, cardRevision, draft);

  @override
  String toString() => 'CardStep($notebookId, r$revision)';
}

/// Make the brief from [notebookId] at [revision].
class BriefStep extends CatchUpStep {
  const BriefStep({required this.notebookId, required this.revision});

  @override
  final String notebookId;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is BriefStep &&
      other.notebookId == notebookId &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(BriefStep, notebookId, revision);

  @override
  String toString() => 'BriefStep($notebookId, r$revision)';
}

/// Build the [missing] search vectors of [notebookId].
class VectorsStep extends CatchUpStep {
  const VectorsStep({
    required this.notebookId,
    required this.entityCount,
    required this.missing,
  });

  @override
  final String notebookId;
  final int entityCount;
  final int missing;

  @override
  bool operator ==(Object other) =>
      other is VectorsStep &&
      other.notebookId == notebookId &&
      other.entityCount == entityCount &&
      other.missing == missing;

  @override
  int get hashCode =>
      Object.hash(VectorsStep, notebookId, entityCount, missing);

  @override
  String toString() => 'VectorsStep($notebookId, $missing missing)';
}

/// Run erase job [jobId] from batch [nextBatch] on, one numbered batch at a
/// time (`forget_erase_batch`).
class EraseStep extends CatchUpStep {
  const EraseStep({required this.jobId, required this.nextBatch});

  final String jobId;
  final int nextBatch;

  @override
  String? get notebookId => null;

  @override
  bool operator ==(Object other) =>
      other is EraseStep &&
      other.jobId == jobId &&
      other.nextBatch == nextBatch;

  @override
  int get hashCode => Object.hash(EraseStep, jobId, nextBatch);

  @override
  String toString() => 'EraseStep($jobId, batch $nextBatch)';
}

/// An ordered catch-up plan.
class CatchUpPlan {
  const CatchUpPlan({
    required this.steps,
    this.truncated = false,
  });

  final List<CatchUpStep> steps;

  /// The server listed at most 50 notebooks per kind; more remain for the
  /// next catch-up.
  final bool truncated;

  bool get isEmpty => steps.isEmpty;

  /// Committing turns moves a notebook's revision, so the card (and brief)
  /// the server listed before may be for an older revision, and a notebook
  /// whose turns only lived on this phone was not listed at all. After the
  /// turn steps, read `get_unfinished_work()` again and plan once more.
  bool get replanAfterTurns => steps.any((step) => step is FinishTurnsStep);

  List<CatchUpStep> stepsFor(String notebookId) => [
        for (final step in steps)
          if (step.notebookId == notebookId) step,
      ];
}

/// Orders catch-up work. Pure: no I/O, no clock.
abstract final class CatchUpPlanner {
  /// The open notebook first (its turns, then card, brief, vectors), then
  /// every other notebook with work, each kept together in the same order,
  /// newest first; erase jobs last.
  ///
  /// "Newest first" without timestamps: [journalNotebookIds] (newest turn
  /// first, from `TurnJournalService.listNotebookIdsWithTurns`) come first,
  /// since their words exist only on this phone, then notebooks in the order
  /// the server lists them (cards, briefs, vectors; each newest first).
  static CatchUpPlan plan({
    required String? openNotebookId,
    required List<String> journalNotebookIds,
    required UnfinishedWork serverWork,
  }) {
    final order = <String>[
      if (openNotebookId != null) openNotebookId,
      ...journalNotebookIds,
      for (final card in serverWork.cards) card.notebookId,
      for (final brief in serverWork.briefs) brief.notebookId,
      for (final vectors in serverWork.vectors) vectors.notebookId,
    ];
    final journal = journalNotebookIds.toSet();

    final steps = <CatchUpStep>[];
    for (final notebookId in LinkedHashSet<String>.from(order)) {
      if (journal.contains(notebookId)) {
        steps.add(FinishTurnsStep(notebookId: notebookId));
      }
      for (final card in serverWork.cards) {
        if (card.notebookId != notebookId) continue;
        steps.add(CardStep(
          notebookId: notebookId,
          revision: card.revision,
          cardRevision: card.cardRevision,
          draft: card.draft,
        ));
      }
      for (final brief in serverWork.briefs) {
        if (brief.notebookId != notebookId) continue;
        steps.add(BriefStep(notebookId: notebookId, revision: brief.revision));
      }
      for (final vectors in serverWork.vectors) {
        if (vectors.notebookId != notebookId) continue;
        steps.add(VectorsStep(
          notebookId: notebookId,
          entityCount: vectors.entityCount,
          missing: vectors.missing,
        ));
      }
    }
    for (final job in serverWork.erase) {
      steps.add(EraseStep(jobId: job.jobId, nextBatch: job.nextBatch));
    }
    return CatchUpPlan(steps: steps, truncated: serverWork.truncated);
  }
}

// ── The runner (LM-103) ─────────────────────────────────────────────────────

/// How one catch-up step ended. Everything other than [done] and
/// [terminal] leaves the work where the next catch-up finds it again.
enum CatchUpOutcome {
  /// Finished (or found already finished).
  done,

  /// Not finished now; tried again next time. For a turn step: a turn was
  /// deferred. For a card or brief: the notebook still has journalled turns
  /// (a card now would miss them).
  deferred,

  /// The notebook has a live session (or, for turns, is open): the session
  /// owns it.
  skippedLive,

  /// A turn step from an earlier run that timed out is still going.
  stillRunning,

  /// The runtime will not write it at this revision (nothing to summarize):
  /// remembered, and skipped until the revision moves.
  terminal,

  /// Skipped: an earlier catch-up found it [terminal] at this revision.
  alreadyTerminal,

  /// Threw; the next catch-up tries again.
  failed,

  /// Ran past its timeout. It may still finish in the background; every step
  /// is keyed, so the next catch-up repeating it is safe.
  timedOut,

  /// Search vectors: the phone does not build them; the server's
  /// embed-reconcile sweep does. Checked again next time.
  serverCatchesUp,

  /// The run was cancelled during the step.
  cancelled,
}

@immutable
class CatchUpStepRecord {
  const CatchUpStepRecord(this.step, this.outcome);
  final CatchUpStep step;
  final CatchUpOutcome outcome;

  @override
  String toString() => '$step ${outcome.name}';
}

/// What one run did. Ids, revisions and outcomes only.
@immutable
class CatchUpReport {
  const CatchUpReport({
    this.records = const [],
    this.plans = 0,
    this.cancelled = false,
    this.budgetExhausted = false,
    this.loadFailed = false,
  });

  static const empty = CatchUpReport();

  final List<CatchUpStepRecord> records;

  /// How many plans were made (2 when turns committed and it replanned).
  final int plans;
  final bool cancelled;
  final bool budgetExhausted;

  /// `get_unfinished_work` could not be read (offline, signed out). Only
  /// journalled turns were tried.
  final bool loadFailed;

  int _count<T extends CatchUpStep>() => records
      .where((r) => r.step is T && r.outcome == CatchUpOutcome.done)
      .length;

  int get cardsWritten => _count<CardStep>();
  int get briefsWritten => _count<BriefStep>();
  int get turnNotebooksFinished => _count<FinishTurnsStep>();
}

/// Card and brief steps the runtime refused for good at a revision (it
/// answers 422 for a notebook with nothing to summarize, e.g. entities
/// added by hand and no words). Keys are `card:<notebookId>` and
/// `brief:<notebookId>`, values the revision. Ids and numbers only.
/// `briefTried:<notebookId>` holds the revision a brief request last
/// completed at: listed again at that revision, the brief is terminal.
abstract interface class CatchUpSkipStore {
  Future<Map<String, int>> read();
  Future<void> write(Map<String, int> skips);

  /// Drops every entry (sign-out). Never throws.
  Future<void> clear();
}

class MemoryCatchUpSkipStore implements CatchUpSkipStore {
  Map<String, int> _skips = {};

  @override
  Future<Map<String, int>> read() async => Map.of(_skips);

  @override
  Future<void> write(Map<String, int> skips) async => _skips = Map.of(skips);

  @override
  Future<void> clear() async => _skips = {};
}

/// A small JSON file next to the turn journal. Unreadable means empty: the
/// worst case is one more refused request.
class FileCatchUpSkipStore implements CatchUpSkipStore {
  FileCatchUpSkipStore({Future<Directory> Function()? directoryProvider})
      : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<File> _file() async {
    final root = await _directoryProvider();
    return File('${root.path}/catch_up/skips.json');
  }

  @override
  Future<Map<String, int>> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is int)
            e.key as String: e.value as int,
      };
    } catch (error) {
      debugPrint('catch-up: skips unreadable (${error.runtimeType})');
      return {};
    }
  }

  @override
  Future<void> write(Map<String, int> skips) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(skips), flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('catch-up: skips not cleared (${error.runtimeType})');
    }
  }
}

/// Cancels a run: between steps, and by abandoning the step in flight
/// (which, being keyed, may still finish harmlessly in the background).
class CatchUpCancelToken {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Commits the journalled turns of one notebook (a fresh
/// `HeadlessTurnFinisher(...).finishNotebook` per run).
typedef FinishNotebookTurnsFn = Future<NotebookFinishResult> Function(
  String notebookId,
);

/// Executes catch-up plans (LM-103): one step at a time, within a total
/// [budget] and a per-step [stepTimeout], cancellable, and never throwing.
/// A step that fails is logged by id and left for the next catch-up.
///
/// A run: read the journal and `get_unfinished_work`, plan, finish the
/// journalled turns, then (if any turn committed) read the work again and
/// plan once more, since a commit moves the revision the card is for; then
/// the cards, briefs, vectors and erase jobs, in plan order.
class CatchUpRunner {
  CatchUpRunner({
    required Future<UnfinishedWork> Function() loadWork,
    required Future<List<String>> Function() journalNotebookIds,
    required FinishNotebookTurnsFn Function() newTurnFinisher,
    required Future<int?> Function(String notebookId) closeCard,
    required Future<void> Function(String notebookId) requestBrief,
    required Future<bool> Function(String jobId) runErase,
    Future<void> Function(VectorsStep step)? buildVectors,
    required CatchUpSkipStore skips,
    String? Function()? openNotebookId,
    bool Function(String notebookId)? isNotebookLive,
    Set<String>? turnsStillRunning,
    this.budget = defaultBudget,
    this.stepTimeout = defaultStepTimeout,
    DateTime Function()? now,
    Future<void> Function(Duration duration)? delay,
    void Function(Set<String> notebookIds)? onPendingCards,
  })  : _loadWork = loadWork,
        _journalNotebookIds = journalNotebookIds,
        _newTurnFinisher = newTurnFinisher,
        _closeCard = closeCard,
        _requestBrief = requestBrief,
        _runErase = runErase,
        _buildVectors = buildVectors,
        _skips = skips,
        _openNotebookId = openNotebookId ?? (() => null),
        _isNotebookLive = isNotebookLive ?? ((_) => false),
        _turnsStillRunning = turnsStillRunning ?? <String>{},
        _now = now ?? DateTime.now,
        _delay = delay ?? ((d) => Future<void>.delayed(d)),
        _onPendingCards = onPendingCards;

  static const defaultBudget = Duration(seconds: 60);
  static const defaultStepTimeout = Duration(seconds: 25);

  final Duration budget;
  final Duration stepTimeout;

  final Future<UnfinishedWork> Function() _loadWork;
  final Future<List<String>> Function() _journalNotebookIds;
  final FinishNotebookTurnsFn Function() _newTurnFinisher;
  final Future<int?> Function(String notebookId) _closeCard;
  final Future<void> Function(String notebookId) _requestBrief;
  final Future<bool> Function(String jobId) _runErase;
  final Future<void> Function(VectorsStep step)? _buildVectors;
  final CatchUpSkipStore _skips;
  final String? Function() _openNotebookId;
  final bool Function(String notebookId) _isNotebookLive;

  /// Notebooks whose turn step timed out in an earlier run and is still
  /// going: not started twice. Shared across runs by the scheduler.
  final Set<String> _turnsStillRunning;
  final DateTime Function() _now;
  final Future<void> Function(Duration duration) _delay;
  final void Function(Set<String> notebookIds)? _onPendingCards;

  /// Runs once. Never throws.
  Future<CatchUpReport> run([CatchUpCancelToken? cancel]) async {
    // Taken before any await: the budget starts when the run is asked for.
    final started = _now();
    final token = cancel ?? CatchUpCancelToken();
    final records = <CatchUpStepRecord>[];
    var plans = 0;
    var loadFailed = false;
    var budgetExhausted = false;
    final pending = <String>{};

    void publish() => _onPendingCards?.call(Set.unmodifiable(pending));

    Duration? remaining() {
      final left = budget - _now().difference(started);
      return left <= Duration.zero ? null : left;
    }

    CatchUpReport report() => CatchUpReport(
          records: List.unmodifiable(records),
          plans: plans,
          cancelled: token.isCancelled,
          budgetExhausted: budgetExhausted,
          loadFailed: loadFailed,
        );

    try {
      // The two opening reads are bounded like any step: a half-open
      // connection must not hang the run (and, the scheduler being
      // single-flight, every later launch and resume with it).
      Future<_Raced> guarded(Future<Object?> read) {
        final left = remaining();
        if (left == null) return Future.value(const _TimedOut());
        return _race(read, left, token);
      }

      Future<UnfinishedWork> load() async {
        final Future<UnfinishedWork> read;
        try {
          read = _loadWork();
        } catch (error) {
          loadFailed = true;
          debugPrint('catch-up: work list unread (${error.runtimeType})');
          return UnfinishedWork.empty;
        }
        switch (await guarded(read)) {
          case _Value(:final value):
            return value as UnfinishedWork;
          case _Error(:final error):
            loadFailed = true;
            debugPrint('catch-up: work list unread (${error.runtimeType})');
          case _TimedOut():
            loadFailed = true;
            debugPrint('catch-up: work list timed out');
          case _Cancelled():
            loadFailed = true;
        }
        return UnfinishedWork.empty;
      }

      Future<List<String>> readJournal(List<String> fallback) async {
        final Future<List<String>> read;
        try {
          read = _journalNotebookIds();
        } catch (error) {
          debugPrint('catch-up: journal unread (${error.runtimeType})');
          return fallback;
        }
        switch (await guarded(read)) {
          case _Value(:final value):
            return value as List<String>;
          case _Error(:final error):
            debugPrint('catch-up: journal unread (${error.runtimeType})');
          case _TimedOut():
            debugPrint('catch-up: journal read timed out');
          case _Cancelled():
            break;
        }
        return fallback;
      }

      final journal = await readJournal(const []);
      if (token.isCancelled) return report();
      var plan = CatchUpPlanner.plan(
        openNotebookId: _openNotebookId(),
        journalNotebookIds: journal,
        serverWork: await load(),
      );
      if (token.isCancelled) return report();
      plans++;
      final skips = await _readSkips();

      // A live notebook's card is the session's, not ours: no "Finishing
      // up" line on it.
      pending.addAll([
        for (final step in plan.steps)
          if (!_isNotebookLive(step.notebookId ?? '') &&
              ((step is CardStep && !_isSkipped(skips, step)) ||
                  (step is FinishTurnsStep &&
                      _openNotebookId() != step.notebookId &&
                      !_turnsStillRunning.contains(step.notebookId))))
            step.notebookId!,
      ]);
      publish();

      // Turns first: their words exist only on this phone.
      final finish = _newTurnFinisher();
      var committed = false;
      final stillJournalled = <String>{};
      for (final step in plan.steps.whereType<FinishTurnsStep>()) {
        if (token.isCancelled) return report();
        final left = remaining();
        if (left == null) {
          budgetExhausted = true;
          return report();
        }
        final id = step.notebookId;
        if (_isNotebookLive(id) || _openNotebookId() == id) {
          stillJournalled.add(id);
          pending.remove(id);
          publish();
          records.add(CatchUpStepRecord(step, CatchUpOutcome.skippedLive));
          continue;
        }
        if (_turnsStillRunning.contains(id)) {
          stillJournalled.add(id);
          records.add(CatchUpStepRecord(step, CatchUpOutcome.stillRunning));
          continue;
        }
        final work = finish(id);
        final raced = await _race(work, left, token);
        final CatchUpOutcome outcome;
        switch (raced) {
          case _Value(:final value):
            final result = value as NotebookFinishResult;
            if (result.committedTurnIds.isNotEmpty ||
                result.rejectedTurnIds.isNotEmpty) {
              committed = true;
            }
            outcome =
                result.done ? CatchUpOutcome.done : CatchUpOutcome.deferred;
            if (!result.done) stillJournalled.add(id);
          case _Error(:final error):
            _log(step, 'failed', error);
            outcome = CatchUpOutcome.failed;
            stillJournalled.add(id);
          case _TimedOut():
            outcome = CatchUpOutcome.timedOut;
            stillJournalled.add(id);
            _markStillRunning(id, work);
          case _Cancelled():
            outcome = CatchUpOutcome.cancelled;
            // Abandoned, not stopped: a run after the unlock must not start
            // a second finisher on the same notebook meanwhile.
            _markStillRunning(id, work);
        }
        if (outcome != CatchUpOutcome.done) {
          debugPrint('catch-up: $step ${outcome.name}');
        }
        records.add(CatchUpStepRecord(step, outcome));
        if (outcome == CatchUpOutcome.cancelled) return report();
      }

      if (committed && !token.isCancelled && remaining() != null) {
        // The commits moved revisions: ask again what is left.
        final failedBefore = loadFailed;
        loadFailed = false;
        final again = await load();
        if (!loadFailed) {
          final journalNow = await readJournal(journal);
          plan = CatchUpPlanner.plan(
            openNotebookId: _openNotebookId(),
            journalNotebookIds: journalNow,
            serverWork: again,
          );
          plans++;
        }
        loadFailed = loadFailed || failedBefore;
      }

      final rest = [
        for (final step in plan.steps)
          if (step is! FinishTurnsStep) step,
      ];
      pending
        ..clear()
        ..addAll([
          for (final step in rest)
            if (step is CardStep &&
                !_isSkipped(skips, step) &&
                !stillJournalled.contains(step.notebookId) &&
                !_isNotebookLive(step.notebookId))
              step.notebookId,
        ]);
      publish();

      for (final step in rest) {
        if (token.isCancelled) return report();
        final left = remaining();
        if (left == null) {
          budgetExhausted = true;
          return report();
        }
        final outcome =
            await _runStep(step, skips, stillJournalled, left, token);
        records.add(CatchUpStepRecord(step, outcome));
        if (step is CardStep && pending.remove(step.notebookId)) publish();
        if (outcome == CatchUpOutcome.cancelled) return report();
      }
      return report();
    } catch (error) {
      // Nothing escapes into the app.
      debugPrint('catch-up: run stopped (${error.runtimeType})');
      return report();
    } finally {
      // Whatever is left waits for the next catch-up; nothing shows as
      // pending in between.
      pending.clear();
      publish();
    }
  }

  void _markStillRunning(String notebookId, Future<Object?> work) {
    _turnsStillRunning.add(notebookId);
    work
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _turnsStillRunning.remove(notebookId));
  }

  Future<CatchUpOutcome> _runStep(
    CatchUpStep step,
    Map<String, int> skips,
    Set<String> stillJournalled,
    Duration left,
    CatchUpCancelToken token,
  ) async {
    final id = step.notebookId;
    if (id != null) {
      if (_isNotebookLive(id)) return CatchUpOutcome.skippedLive;
      if ((step is CardStep || step is BriefStep) &&
          stillJournalled.contains(id)) {
        return CatchUpOutcome.deferred;
      }
    }
    switch (step) {
      case CardStep():
        if (_isSkipped(skips, step)) return CatchUpOutcome.alreadyTerminal;
        final raced = await _race(_closeCard(step.notebookId), left, token);
        return _settle(step, raced, skips, (value) {
          final revision = value as int?;
          // No card, or one for an older revision: the runtime will answer
          // the same at this revision (nothing to summarize).
          return revision == null || revision < step.revision
              ? CatchUpOutcome.terminal
              : CatchUpOutcome.done;
        });
      case BriefStep():
        if (_isSkipped(skips, step)) return CatchUpOutcome.alreadyTerminal;
        final tried = 'briefTried:${step.notebookId}';
        if (skips[tried] == step.revision) {
          // A request at this revision completed last time, yet the server
          // still lists no brief (it saved nothing, e.g. `unchanged`): asking
          // again would pay for the model once more for the same answer.
          skips.remove(tried);
          return _settle(
              step, const _Value(null), skips, (_) => CatchUpOutcome.terminal);
        }
        final raced = await _race(_requestBrief(step.notebookId), left, token);
        final outcome =
            await _settle(step, raced, skips, (_) => CatchUpOutcome.done);
        if (outcome == CatchUpOutcome.done) {
          try {
            skips[tried] = step.revision;
            await _skips.write(skips);
          } catch (error) {
            debugPrint('catch-up: skips not saved (${error.runtimeType})');
          }
        }
        return outcome;
      case VectorsStep():
        final build = _buildVectors;
        if (build == null) {
          debugPrint('catch-up: $step vectors: server catches up');
          return CatchUpOutcome.serverCatchesUp;
        }
        final raced = await _race(build(step), left, token);
        return _settle(step, raced, skips, (_) => CatchUpOutcome.done);
      case EraseStep():
        final raced = await _race(_runErase(step.jobId), left, token);
        return _settle(
          step,
          raced,
          skips,
          (finished) =>
              finished == true ? CatchUpOutcome.done : CatchUpOutcome.failed,
        );
      case FinishTurnsStep():
        // Handled before the other steps.
        return CatchUpOutcome.deferred;
    }
  }

  Future<CatchUpOutcome> _settle(
    CatchUpStep step,
    _Raced raced,
    Map<String, int> skips,
    CatchUpOutcome Function(Object? value) onValue,
  ) async {
    var outcome = switch (raced) {
      _Value(:final value) => onValue(value),
      _Error(:final error) => _isTerminal(step, error)
          ? CatchUpOutcome.terminal
          : CatchUpOutcome.failed,
      _TimedOut() => CatchUpOutcome.timedOut,
      _Cancelled() => CatchUpOutcome.cancelled,
    };
    if (raced is _Error && outcome == CatchUpOutcome.failed) {
      _log(step, 'failed', raced.error);
    } else if (outcome != CatchUpOutcome.done) {
      debugPrint('catch-up: $step ${outcome.name}');
    }
    final key = _skipKey(step);
    if (key != null) {
      final revision =
          step is CardStep ? step.revision : (step as BriefStep).revision;
      try {
        if (outcome == CatchUpOutcome.terminal) {
          skips[key] = revision;
          await _skips.write(skips);
        } else if (outcome == CatchUpOutcome.done &&
            skips.remove(key) != null) {
          await _skips.write(skips);
        }
      } catch (error) {
        debugPrint('catch-up: skips not saved (${error.runtimeType})');
      }
    }
    return outcome;
  }

  static bool _isTerminal(CatchUpStep step, Object error) =>
      step is BriefStep &&
      error is SessionBriefException &&
      error.statusCode == 422;

  static String? _skipKey(CatchUpStep step) => switch (step) {
        CardStep(:final notebookId) => 'card:$notebookId',
        BriefStep(:final notebookId) => 'brief:$notebookId',
        _ => null,
      };

  static bool _isSkipped(Map<String, int> skips, CatchUpStep step) {
    final key = _skipKey(step);
    if (key == null) return false;
    final revision =
        step is CardStep ? step.revision : (step as BriefStep).revision;
    return skips[key] == revision;
  }

  Future<Map<String, int>> _readSkips() async {
    try {
      return await _skips.read();
    } catch (error) {
      debugPrint('catch-up: skips unreadable (${error.runtimeType})');
      return {};
    }
  }

  /// The step's result, or whichever of its timeout or the cancel comes
  /// first. The step itself is not stopped; it is only no longer waited on.
  Future<_Raced> _race(
    Future<Object?> work,
    Duration limit,
    CatchUpCancelToken token,
  ) {
    final limited = limit < stepTimeout ? limit : stepTimeout;
    final out = Completer<_Raced>();
    work.then(
      (value) {
        if (!out.isCompleted) out.complete(_Value(value));
      },
      onError: (Object error) {
        if (!out.isCompleted) out.complete(_Error(error));
      },
    );
    _delay(limited).then((_) {
      if (!out.isCompleted) out.complete(const _TimedOut());
    });
    token.whenCancelled.then((_) {
      if (!out.isCompleted) out.complete(const _Cancelled());
    });
    return out.future;
  }

  // Ids and the error's type only: never text.
  static void _log(CatchUpStep step, String what, Object error) =>
      debugPrint('catch-up: $step $what (${error.runtimeType})');
}

sealed class _Raced {
  const _Raced();
}

class _Value extends _Raced {
  const _Value(this.value);
  final Object? value;
}

class _Error extends _Raced {
  const _Error(this.error);
  final Object error;
}

class _TimedOut extends _Raced {
  const _TimedOut();
}

class _Cancelled extends _Raced {
  const _Cancelled();
}

/// Starts catch-up runs: one at a time (launch and resume never overlap),
/// and only while the app lock is open.
///
/// A [request] while a run is going is coalesced: at most one follow-up run
/// starts when the current one ends (the trigger may mean the network is
/// back). A [request] while locked waits for [setUnlocked]. Locking cancels
/// the run in flight and asks again for after the next unlock. [signedOut]
/// cancels and forgets every request.
class CatchUpScheduler {
  CatchUpScheduler({
    required Future<CatchUpReport> Function(CatchUpCancelToken token) run,
    void Function(bool running)? onRunning,
    void Function(CatchUpReport report)? onReport,
  })  : _run = run,
        _onRunning = onRunning,
        _onReport = onReport;

  final Future<CatchUpReport> Function(CatchUpCancelToken token) _run;
  final void Function(bool running)? _onRunning;
  final void Function(CatchUpReport report)? _onReport;

  bool _unlocked = false;
  bool _wanted = false;
  bool _again = false;
  CatchUpCancelToken? _token;
  Future<void>? _current;

  bool get isRunning => _current != null;

  /// The run in flight, if any (tests wait on it).
  Future<void>? get current => _current;

  /// Asks for a run (launch, resume). Never throws; never waits.
  void request() {
    if (!_unlocked) {
      _wanted = true;
      return;
    }
    if (_current != null) {
      _again = true;
      return;
    }
    _start();
  }

  void setUnlocked(bool unlocked) {
    if (unlocked == _unlocked) return;
    _unlocked = unlocked;
    if (!unlocked) {
      if (_current != null) {
        _token?.cancel();
        _again = false;
        _wanted = true;
      }
      return;
    }
    if (_wanted) {
      _wanted = false;
      request();
    }
  }

  /// Stops the current run (if any) without dropping later requests.
  void cancel() {
    _token?.cancel();
    _again = false;
  }

  void signedOut() {
    cancel();
    _wanted = false;
  }

  void _start() {
    final token = _token = CatchUpCancelToken();
    final done = Completer<void>();
    _current = done.future;
    _onRunning?.call(true);
    // _drive never throws, and a run that throws synchronously still lands
    // here asynchronously, after _current is set: the scheduler is never
    // left "running".
    _drive(token).whenComplete(() {
      if (identical(_current, done.future)) _current = null;
      if (identical(_token, token)) _token = null;
      try {
        _onRunning?.call(false);
      } catch (error) {
        debugPrint('catch-up: state not updated (${error.runtimeType})');
      }
      done.complete();
      if (_again && _unlocked) {
        _again = false;
        _start();
      }
    });
  }

  Future<void> _drive(CatchUpCancelToken token) async {
    try {
      final report = await Future.sync(() => _run(token));
      _onReport?.call(report);
    } catch (error) {
      debugPrint('catch-up: run failed (${error.runtimeType})');
    }
  }
}
