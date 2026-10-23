// LM-12: a typed turn is its own user turn, finalized the moment it is sent,
// and never merged into a voice turn that is still transcribing.
import 'package:flutter_test/flutter_test.dart';

import 'package:lumen/logic/turn_state.dart';

/// Deterministic ids and clock (one second per tick from 2026-01-01).
TurnMachine machine() {
  var turnSeq = 0;
  var reqSeq = 0;
  var clock = 0;
  return TurnMachine(
    now: () =>
        DateTime.utc(2026, 1, 1).add(Duration(seconds: clock++)).toIso8601String(),
    newTurnId: () => 'turn-${++turnSeq}',
    newRequestId: () => 'req-${++reqSeq}',
  );
}

TurnMachine started() {
  final m = machine();
  m.dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'));
  return m;
}

/// Well after the machine's clock, so typed turns sort last unless a test
/// says otherwise.
const _later = '2026-01-01T00:10:00.000Z';

void main() {
  test('a typed turn finalizes at once, with its own id and input: typed', () {
    final m = started();

    final effects = m.dispatch(
      const TypedTurnSubmitted(text: '  I met Priya.  ', submittedAt: _later),
    );

    final turn = m.state.pending.single;
    expect(turn.speaker, Speaker.user);
    expect(turn.input, TurnInput.typed);
    expect(turn.transcript, 'I met Priya.');
    expect(turn.stage, DurableStage.finalRecorded);
    expect(turn.turnId, isNotEmpty);
    // Checkpointed before extraction, exactly like a spoken turn.
    final persist = effects.indexWhere((e) => e is PersistTurn);
    final extract = effects.indexWhere((e) => e is StartDurableExtraction);
    expect(persist, greaterThanOrEqualTo(0));
    expect(extract, greaterThan(persist));
    expect(
      effects.whereType<StartDurableExtraction>().single.transcript,
      'I met Priya.',
    );

    final row = m.state.conversation.single;
    expect(row.turnId, turn.turnId);
    expect(row.input, TurnInput.typed);
    expect(row.startedAt, _later, reason: 'spoken order follows the send');
    expect(m.state.activeUser, isNull, reason: 'no interim turn is opened');
    expect(m.inProgress, isEmpty);
  });

  test('spoken turns default to input: voice', () {
    final m = started();
    m.dispatch(const InterimTranscript(speaker: Speaker.user, text: 'Hi'));
    m.dispatch(const FinalTranscript(speaker: Speaker.user, text: 'Hi.'));
    m.dispatch(const TurnCompleted(speaker: Speaker.user));

    expect(m.state.pending.single.input, TurnInput.voice);
    expect(m.state.conversation.single.input, TurnInput.voice);
  });

  test('blank typed text, or text before the session, does nothing', () {
    final idle = machine();
    expect(
      idle.dispatch(const TypedTurnSubmitted(text: 'Hello', submittedAt: _later)),
      isEmpty,
    );
    expect(idle.state.conversation, isEmpty);

    final m = started();
    expect(
      m.dispatch(const TypedTurnSubmitted(text: '  \n ', submittedAt: _later)),
      isEmpty,
    );
    expect(m.state.pending, isEmpty);
    expect(m.state.conversation, isEmpty);
  });

  test('two typed turns are two turns, in the order they were sent', () {
    final m = started();
    m.dispatch(const TypedTurnSubmitted(
        text: 'First.', submittedAt: '2026-01-01T00:10:00.000Z'));
    m.dispatch(const TypedTurnSubmitted(
        text: 'Second.', submittedAt: '2026-01-01T00:10:05.000Z'));

    expect([for (final t in m.state.conversation) t.text], ['First.', 'Second.']);
    expect(m.state.pending.map((t) => t.turnId).toSet(), hasLength(2));
    expect(m.state.pending.map((t) => t.commitRequestId).toSet(), hasLength(2));
  });

  group('beside a voice turn', () {
    test('a voice turn awaiting its final is left intact, and both finalize '
        'in spoken order', () {
      final m = started();
      m.dispatch(const InterimTranscript(
          speaker: Speaker.user, text: 'I finished the Atlas draft'));
      m.dispatch(const TurnCompleted(speaker: Speaker.user));
      final voice = m.state.awaitingUser!;

      m.dispatch(const TypedTurnSubmitted(
          text: 'Also, Maya signed off.', submittedAt: _later));

      // The voice turn is untouched: same id, same text, still awaiting.
      expect(m.state.awaitingUser, same(voice));
      expect(voice.text, 'I finished the Atlas draft');
      expect(voice.finalText, isNull);
      expect(m.state.conversation.single.text, 'Also, Maya signed off.');

      m.dispatch(const FinalTranscript(
          speaker: Speaker.user, text: 'I finished the Atlas draft.'));

      expect(m.state.awaitingUser, isNull);
      expect(
        [for (final t in m.state.conversation) (t.text, t.input)],
        [
          ('I finished the Atlas draft.', TurnInput.voice),
          ('Also, Maya signed off.', TurnInput.typed),
        ],
      );
      expect(m.state.pending.map((t) => t.turnId).toSet(), hasLength(2));
    });

    test('a voice turn still being spoken keeps its interim text', () {
      final m = started();
      m.dispatch(
          const InterimTranscript(speaker: Speaker.user, text: 'I was going'));
      final voice = m.state.activeUser!;

      m.dispatch(const TypedTurnSubmitted(text: 'Typed.', submittedAt: _later));

      expect(m.state.activeUser, same(voice));
      expect(voice.text, 'I was going');
      expect(m.inProgress.single.text, 'I was going');

      // Later interim text still goes to the voice turn, not the typed one.
      m.dispatch(const InterimTranscript(
          speaker: Speaker.user, text: 'I was going to say'));
      m.dispatch(const FinalTranscript(
          speaker: Speaker.user, text: 'I was going to say.'));
      m.dispatch(const TurnCompleted(speaker: Speaker.user));
      expect(
        [for (final t in m.state.conversation) t.text],
        ['I was going to say.', 'Typed.'],
      );
    });
  });

  group('while Lumen is speaking', () {
    const reply = 'You mentioned Acme. Your sister Mia lives in Oslo.';

    test('it interrupts Lumen at the heard prefix', () {
      final m = started();
      m.dispatch(const InterimTranscript(speaker: Speaker.assistant, text: reply));
      m.dispatch(const PlaybackAdvanced(heardChars: 21));

      final effects = m.dispatch(
          const TypedTurnSubmitted(text: 'Wait, Acme?', submittedAt: _later));

      expect(effects.whereType<FlushPlayback>(), hasLength(1));
      expect(m.state.activeAssistant, isNull);
      final lumen = m.state.pending.first;
      expect(lumen.speaker, Speaker.assistant);
      expect(lumen.transcript, 'You mentioned Acme.');
      expect(lumen.truncatedFromInterruption, isTrue);
      expect(
        [for (final t in m.state.conversation) (t.role, t.text)],
        [
          (Speaker.assistant, 'You mentioned Acme.'),
          (Speaker.user, 'Wait, Acme?'),
        ],
      );
    });

    test('unheard words of the cut-off reply never come back', () {
      final m = started();
      m.dispatch(const InterimTranscript(speaker: Speaker.assistant, text: reply));
      m.dispatch(const PlaybackAdvanced(heardChars: 21));
      m.dispatch(
          const TypedTurnSubmitted(text: 'Wait, Acme?', submittedAt: _later));

      // Gemini's own signals for the cut-off reply, as recorded by
      // test/gemini_live_typed_turn_probe.dart: interrupted, then
      // turnComplete — plus a late transcript of the unheard tail.
      m.dispatch(const FinalTranscript(speaker: Speaker.assistant, text: reply));
      m.dispatch(const AssistantInterrupted(heardChars: null));
      m.dispatch(const TurnCompleted(speaker: Speaker.assistant));

      final everything = [
        ...m.state.pending.map((t) => t.transcript),
        ...m.state.conversation.map((t) => t.text),
      ].join(' ');
      expect(everything, isNot(contains('Oslo')));
      expect(m.state.conversation, hasLength(2));

      // Lumen's answer to the typed turn is accepted as a new turn.
      m.dispatch(const InterimTranscript(
          speaker: Speaker.assistant, text: 'Yes, Acme.'));
      expect(m.state.activeAssistant?.text, 'Yes, Acme.');
    });

    test('nothing heard yet means nothing of the reply is kept', () {
      final m = started();
      m.dispatch(const InterimTranscript(speaker: Speaker.assistant, text: reply));

      final effects = m.dispatch(
          const TypedTurnSubmitted(text: 'Stop.', submittedAt: _later));

      expect(effects.whereType<FlushPlayback>(), hasLength(1));
      expect(m.state.activeAssistant, isNull);
      expect([for (final t in m.state.conversation) t.text], ['Stop.']);
    });

    test('a reply already finished is not interrupted', () {
      final m = started();
      m.dispatch(const InterimTranscript(speaker: Speaker.assistant, text: reply));
      m.dispatch(const FinalTranscript(speaker: Speaker.assistant, text: reply));
      m.dispatch(const TurnCompleted(speaker: Speaker.assistant));

      final effects = m.dispatch(
          const TypedTurnSubmitted(text: 'Thanks.', submittedAt: _later));

      expect(effects.whereType<FlushPlayback>(), isEmpty);
      expect(m.state.conversation.first.text, reply);
    });
  });

  test('a crash after a typed turn finalizes is recovered from the journal',
      () {
    final m = started();
    final persisted = m
        .dispatch(const TypedTurnSubmitted(text: 'I met Priya.', submittedAt: _later))
        .whereType<PersistTurn>()
        .single
        .turn;

    // The journal stores JSON; a restart reads it back.
    final stored = FinalizedTurn.fromJson(persisted.toJson());
    expect(stored.input, TurnInput.typed);

    final restarted = machine();
    restarted.dispatch(const SessionStarted(sessionId: 's2', notebookId: 'nb1'));
    final effects = restarted.dispatch(Restored(turns: [stored]));

    final extract = effects.whereType<StartDurableExtraction>().single;
    expect(extract.transcript, 'I met Priya.');
    expect(extract.key.turnId, persisted.turnId);
    final head = restarted.state.pending.single;
    expect(head.commitRequestId, persisted.commitRequestId);
    expect(head.input, TurnInput.typed);

    // Its input survives every later checkpoint, too.
    final next = restarted.dispatch(DurableExtractionSucceeded(
      key: extract.key,
      payload: const {'entities': <Object>[], 'relations': <Object>[]},
    ));
    for (final checkpoint in next.whereType<PersistTurn>()) {
      expect(checkpoint.turn.input, TurnInput.typed);
    }
  });

  test('a journal entry written before typed turns existed reads as voice', () {
    final json = FinalizedTurn(
      turnId: 'turn-1',
      sessionId: 's1',
      notebookId: 'nb1',
      speaker: Speaker.user,
      transcript: 'Hi.',
      transcriptVersion: 1,
      transcriptHash: fnv1a('Hi.'),
      extractorVersion: 'v1',
      generation: 1,
      commitRequestId: 'req-1',
      stage: DurableStage.finalRecorded,
      finalizedAt: '2026-01-01T00:00:00.000Z',
    ).toJson()
      ..remove('input');

    expect(FinalizedTurn.fromJson(json).input, TurnInput.voice);
  });
}
