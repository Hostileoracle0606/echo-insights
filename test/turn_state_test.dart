import 'package:flutter_test/flutter_test.dart';

import 'package:lumen/logic/turn_state.dart';

/// Deterministic ids and clock so every assertion can name what it expects.
TurnMachine machine({bool provisionalExtraction = false}) {
  var turnSeq = 0;
  var reqSeq = 0;
  var clock = 0;
  return TurnMachine(
    now: () => DateTime.utc(2026, 1, 1).add(Duration(seconds: clock++)).toIso8601String(),
    newTurnId: () => 'turn-${++turnSeq}',
    newRequestId: () => 'req-${++reqSeq}',
    provisionalExtraction: provisionalExtraction,
  );
}

const _payload = {
  'entities': [
    {'name': 'Acme', 'type': 'organization'},
  ],
  'relations': <Object>[],
};

void main() {
  group('session lifecycle', () {
    test('activation records the session, notebook, and loaded revision', () {
      final m = machine();

      m.dispatch(const SessionStarted(
        sessionId: 's1',
        notebookId: 'nb1',
        revision: 7,
      ));

      expect(m.state.sessionId, 's1');
      expect(m.state.notebookId, 'nb1');
      expect(m.state.revision, 7);
    });

    test('transcripts remain inert until the session is activated', () {
      final m = machine();

      final beforeActivation = m.dispatch(
        const FinalTranscript(speaker: Speaker.user, text: 'I work at Acme.'),
      );
      expect(beforeActivation, isEmpty);
      expect(m.state.activeUser, isNull);

      m.dispatch(const SessionStarted(
        sessionId: 's1',
        notebookId: 'nb1',
        revision: 7,
      ));
      m.dispatch(
        const FinalTranscript(speaker: Speaker.user, text: 'I work at Acme.'),
      );
      final afterActivation = m.dispatch(
        const TurnCompleted(speaker: Speaker.user),
      );

      expect(afterActivation.whereType<StartDurableExtraction>(), isNotEmpty);
      expect(m.state.conversation.single.text, 'I work at Acme.');
    });
  });

  group('interim transcripts', () {
    test('interim text is replaceable display state and bumps the version', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));

      m.dispatch(const InterimTranscript(speaker: Speaker.user, text: 'I work at Acne.'));
      m.dispatch(const InterimTranscript(speaker: Speaker.user, text: 'I work at Acme.'));

      expect(m.state.activeUser!.text, 'I work at Acme.');
      expect(m.state.activeUser!.transcriptVersion, 2);
      expect(m.state.pending, isEmpty);
    });
  });

  group('finalization', () {
    test('cumulative prefixes produce exactly one durable turn', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));

      m.dispatch(const InterimTranscript(speaker: Speaker.user, text: 'I work at Acme.'));
      m.dispatch(const InterimTranscript(
          speaker: Speaker.user, text: 'I work at Acme. My manager is Sarah.'));
      m.dispatch(const FinalTranscript(
          speaker: Speaker.user, text: 'I work at Acme. My manager is Sarah.'));
      m.dispatch(const TurnCompleted(speaker: Speaker.user));

      expect(m.state.pending, hasLength(1));
      expect(m.state.pending.first.transcript, 'I work at Acme. My manager is Sarah.');
      expect(m.state.pending.first.stage, DurableStage.finalRecorded);
    });

    test('final transcription arriving BEFORE turn completion works', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      m.dispatch(const InterimTranscript(speaker: Speaker.user, text: 'I work at Acne'));

      m.dispatch(const FinalTranscript(speaker: Speaker.user, text: 'I work at Acme.'));
      expect(m.state.pending, isEmpty);

      final effects = m.dispatch(const TurnCompleted(speaker: Speaker.user));
      expect(m.state.pending, hasLength(1));
      expect(m.state.pending.first.transcript, 'I work at Acme.');
      expect(effects.whereType<StartDurableExtraction>(), isNotEmpty);
    });

    test('final transcription arriving AFTER turn completion works', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      m.dispatch(const InterimTranscript(speaker: Speaker.user, text: 'I work at Acne'));

      final completed = m.dispatch(const TurnCompleted(speaker: Speaker.user));
      expect(m.state.pending, isEmpty);
      expect(completed.whereType<ScheduleFinalizationDeadline>(), isNotEmpty);

      m.dispatch(const FinalTranscript(speaker: Speaker.user, text: 'I work at Acme.'));
      expect(m.state.pending, hasLength(1));
      expect(m.state.pending.first.transcript, 'I work at Acme.');
    });

    test('a deadline firing after finalization creates no phantom turn', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      m.dispatch(const InterimTranscript(speaker: Speaker.user, text: 'I work at Acme.'));
      m.dispatch(const TurnCompleted(speaker: Speaker.user));
      m.dispatch(const FinalTranscript(speaker: Speaker.user, text: 'I work at Acme.'));

      m.dispatch(const FinalizationDeadline(speaker: Speaker.user, turnId: 'turn-1'));

      expect(m.state.pending, hasLength(1));
    });
  });

  group('generation identity', () {
    test('a late durable result cannot change a different notebook', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      m.dispatch(const InterimTranscript(speaker: Speaker.user, text: 'I work at Acme.'));
      m.dispatch(const TurnCompleted(speaker: Speaker.user));
      final key = m
          .dispatch(const FinalTranscript(speaker: Speaker.user, text: 'I work at Acme.'))
          .whereType<StartDurableExtraction>()
          .first
          .key;

      m.dispatch(const SessionStarted(sessionId: 's2', notebookId: 'nb2'));
      m.dispatch(DurableExtractionSucceeded(key: key, payload: _payload));

      expect(m.state.pending, isEmpty);
      expect(m.state.staleRejections, 1);
    });

    test('a late result whose transcript version moved on is discarded', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      m.dispatch(const InterimTranscript(speaker: Speaker.user, text: 'I work at Acme.'));
      m.dispatch(const TurnCompleted(speaker: Speaker.user));
      final key = m
          .dispatch(const FinalTranscript(speaker: Speaker.user, text: 'I work at Acme.'))
          .whereType<StartDurableExtraction>()
          .first
          .key;

      m.dispatch(DurableExtractionSucceeded(
        key: key.copyWith(transcriptVersion: key.transcriptVersion - 1),
        payload: _payload,
      ));

      expect(m.state.pending.first.extraction, isNull);
      expect(m.state.staleRejections, 1);
    });

    test('a provisional preview never becomes durable', () {
      final m = machine(provisionalExtraction: true);
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      final started = m
          .dispatch(const InterimTranscript(speaker: Speaker.user, text: 'I work at Acme'))
          .whereType<StartProvisionalExtraction>()
          .first;

      m.dispatch(ProvisionalExtractionSettled(
        key: started.key,
        entityNames: const ['Acme'],
      ));

      expect(m.state.previewEntityNames, ['Acme']);
      expect(m.state.pending, isEmpty);
      expect(m.state.conversation, isEmpty);
    });
  });

  group('interrupted assistant speech', () {
    test('only the words actually heard are finalized', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      m.dispatch(const InterimTranscript(
        speaker: Speaker.assistant,
        text: 'You mentioned Acme. Your sister Mia lives in Oslo.',
      ));
      m.dispatch(const PlaybackAdvanced(heardChars: 21));

      m.dispatch(const AssistantInterrupted(heardChars: 21));
      m.dispatch(const TurnCompleted(speaker: Speaker.assistant));

      expect(m.state.pending, hasLength(1));
      expect(m.state.pending.first.transcript, 'You mentioned Acme.');
      expect(m.state.pending.first.truncatedFromInterruption, isTrue);
      expect(m.state.conversation.first.text, 'You mentioned Acme.');
    });

    test('unheard words never enter the durable path', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      m.dispatch(const InterimTranscript(
        speaker: Speaker.assistant,
        text: 'You mentioned Acme. Your sister Mia lives in Oslo.',
      ));
      final effects = m.dispatch(const AssistantInterrupted(heardChars: 21));
      m.dispatch(const TurnCompleted(speaker: Speaker.assistant));

      expect(effects.whereType<FlushPlayback>(), isNotEmpty);
      final durable = m.state.pending.map((t) => t.transcript).join(' ');
      expect(durable, isNot(contains('Mia')));
      expect(durable, isNot(contains('Oslo')));
    });

    test('an undeterminable heard boundary skips durable extraction entirely', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      m.dispatch(const InterimTranscript(
        speaker: Speaker.assistant,
        text: 'You mentioned Acme. Your sister Mia lives in Oslo.',
      ));

      m.dispatch(const AssistantInterrupted(heardChars: null));
      m.dispatch(const TurnCompleted(speaker: Speaker.assistant));

      expect(m.state.pending, isEmpty);
      expect(m.state.conversation, isEmpty);
    });

    test('a late final transcript cannot resurrect unheard text', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      m.dispatch(const InterimTranscript(
          speaker: Speaker.assistant, text: 'You mentioned Acme.'));
      m.dispatch(const AssistantInterrupted(heardChars: 19));
      m.dispatch(const TurnCompleted(speaker: Speaker.assistant));

      m.dispatch(const FinalTranscript(
        speaker: Speaker.assistant,
        text: 'You mentioned Acme. Your sister Mia lives in Oslo.',
      ));

      expect(m.state.pending, hasLength(1));
      expect(m.state.pending.first.transcript, 'You mentioned Acme.');
    });
  });

  group('durable turn processing', () {
    List<TurnEffect> speak(TurnMachine m, String text) {
      m.dispatch(InterimTranscript(speaker: Speaker.user, text: text));
      m.dispatch(const TurnCompleted(speaker: Speaker.user));
      return m.dispatch(FinalTranscript(speaker: Speaker.user, text: text));
    }

    test('the final transcript is checkpointed before extraction runs', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      final effects = speak(m, 'I work at Acme.');

      final persist = effects.indexWhere((e) => e is PersistTurn);
      final extract = effects.indexWhere((e) => e is StartDurableExtraction);
      expect(persist, greaterThanOrEqualTo(0));
      expect(extract, greaterThan(persist));
    });

    test('the extraction result is stored before the commit is attempted', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      final key = speak(m, 'I work at Acme.').whereType<StartDurableExtraction>().first.key;

      final effects = m.dispatch(DurableExtractionSucceeded(key: key, payload: _payload));

      final persist = effects.indexWhere(
        (e) => e is PersistTurn && e.turn.stage == DurableStage.extracted,
      );
      final commit = effects.indexWhere((e) => e is StartCommit);
      expect(persist, greaterThanOrEqualTo(0));
      expect(commit, greaterThan(persist));
      expect(m.state.pending.first.extraction, _payload);
    });

    test('a restart after extraction reuses the stored result', () {
      final stored = FinalizedTurn(
        turnId: 'turn-1',
        sessionId: 's1',
        notebookId: 'nb1',
        speaker: Speaker.user,
        transcript: 'I work at Acme.',
        transcriptVersion: 2,
        transcriptHash: 'abc',
        extractorVersion: 'v1',
        generation: 1,
        commitRequestId: 'req-1',
        stage: DurableStage.extracted,
        extraction: _payload,
        finalizedAt: '2026-01-01T00:00:00.000Z',
      );
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));

      final effects = m.dispatch(Restored(turns: [stored]));

      expect(effects.whereType<StartDurableExtraction>(), isEmpty);
      expect(effects.whereType<StartCommit>(), isNotEmpty);
    });

    test('an unknown commit outcome retries with the SAME request id', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      final key = speak(m, 'I work at Acme.').whereType<StartDurableExtraction>().first.key;
      final first = m
          .dispatch(DurableExtractionSucceeded(key: key, payload: _payload))
          .whereType<StartCommit>()
          .first;

      final retry = m
          .dispatch(const CommitUnknown(turnId: 'turn-1'))
          .whereType<StartCommit>()
          .first;

      expect(retry.commitRequestId, first.commitRequestId);
      expect(m.state.pending.first.stage, DurableStage.commitPending);
    });

    test('pending turns replay in order after a conflict, keeping request ids', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));

      final k1 = speak(m, 'I work at Acme.').whereType<StartDurableExtraction>().first.key;
      m.dispatch(DurableExtractionSucceeded(key: k1, payload: _payload));
      final second = speak(m, 'My manager is Sarah.');
      expect(second.whereType<StartDurableExtraction>(), isEmpty);

      final ids = m.state.pending.map((t) => t.commitRequestId).toList();
      expect(
        m.state.pending.map((t) => t.transcript),
        ['I work at Acme.', 'My manager is Sarah.'],
      );

      final conflict =
          m.dispatch(const CommitConflict(turnId: 'turn-1', currentRevision: 12));
      expect(conflict.whereType<ReloadSnapshot>(), isNotEmpty);
      expect(m.state.revision, 12);

      final retry = m
          .dispatch(const SnapshotReloaded(revision: 12))
          .whereType<StartCommit>()
          .first;

      expect(retry.turnId, 'turn-1');
      expect(m.state.pending.map((t) => t.commitRequestId), ids);
    });

    test('a reconnect to the same notebook keeps finalized durable work', () {
      final m = machine();
      m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
      speak(m, 'I work at Acme.');

      m.dispatch(const SessionStarted(sessionId: 's2', notebookId: 'nb1'));

      expect(m.state.pending, hasLength(1));
      expect(m.state.activeUser, isNull);
    });
  });
}
