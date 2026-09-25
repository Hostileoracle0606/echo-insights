// Warm standby: everything Gemini sends before the user taps (Lumen's
// pre-sent opening) is held back — never reaching the transcript, the turn
// machine, or the speaker — then replayed on activation with each transcript
// signal paced by the audio that preceded it, so words never run ahead of
// Lumen's voice.
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/live_signal_gate.dart';

// 100ms of 24kHz PCM16 mono.
AgentAudio audio100ms() => AgentAudio(Uint8List(4800), 24000);

String describe(LiveSignal signal) => switch (signal) {
      AgentAudio() => 'audio',
      AgentTranscript(:final text, :final isFinal) =>
        'agent:$text${isFinal ? '!' : ''}',
      UserTranscript(:final text) => 'user:$text',
      TurnCompleteSignal() => 'turnComplete',
      InterruptedSignal() => 'interrupted',
    };

void main() {
  test('holds every signal until activation', () {
    final gate = LiveSignalGate();

    gate
      ..receive(audio100ms())
      ..receive(const AgentTranscript('Welcome back', false))
      ..receive(const TurnCompleteSignal());

    expect(gate.isActivated, isFalse);
    expect(gate.buffered, 3);
  });

  test('replays audio at once and paces text by the audio before it', () {
    fakeAsync((async) {
      final gate = LiveSignalGate(now: () => async.elapsed);
      final seen = <(Duration, String)>[];

      gate
        ..receive(audio100ms())
        ..receive(audio100ms())
        ..receive(const AgentTranscript('Welcome', false))
        ..receive(audio100ms())
        ..receive(const AgentTranscript('Welcome back', true))
        ..receive(const TurnCompleteSignal());

      gate.activate((s) => seen.add((async.elapsed, describe(s))));

      // All audio goes straight to the player queue; text waits.
      expect(seen.map((e) => e.$2), ['audio', 'audio', 'audio']);

      async.elapse(const Duration(milliseconds: 200));
      expect(seen.last, (const Duration(milliseconds: 200), 'agent:Welcome'));

      async.elapse(const Duration(milliseconds: 100));
      expect(seen.skip(4).map((e) => e.$2),
          ['agent:Welcome back!', 'turnComplete']);
      expect(gate.isPacing, isFalse);
    });
  });

  test('live signals during pacing queue behind the replay, in order', () {
    fakeAsync((async) {
      final gate = LiveSignalGate(now: () => async.elapsed);
      final seen = <String>[];

      gate
        ..receive(audio100ms())
        ..receive(const AgentTranscript('Hi', false));
      gate.activate((s) => seen.add(describe(s)));

      // The opening is still streaming when the user taps.
      gate
        ..receive(audio100ms())
        ..receive(const AgentTranscript('Hi there', true));
      expect(seen, ['audio', 'audio'], reason: 'text still waits its turn');

      async.elapse(const Duration(milliseconds: 100));
      expect(seen.last, 'agent:Hi');
      async.elapse(const Duration(milliseconds: 100));
      expect(seen.last, 'agent:Hi there!');
    });
  });

  test('after the replay drains, signals pass straight through', () {
    fakeAsync((async) {
      final gate = LiveSignalGate(now: () => async.elapsed);
      final seen = <String>[];
      gate.activate((s) => seen.add(describe(s)));

      gate.receive(const UserTranscript('I met Priya', false));
      expect(seen, ['user:I met Priya']);
    });
  });

  test('nothing buffered: activation is a no-op passthrough', () {
    final gate = LiveSignalGate();
    final seen = <String>[];
    gate.activate((s) => seen.add(describe(s)));
    expect(gate.isPacing, isFalse);
    gate.receive(const TurnCompleteSignal());
    expect(seen, ['turnComplete']);
  });

  test('dispose drops the buffer and any paced signals', () {
    fakeAsync((async) {
      final gate = LiveSignalGate(now: () => async.elapsed);
      final seen = <String>[];
      gate
        ..receive(audio100ms())
        ..receive(const AgentTranscript('Hi', true));
      gate.activate((s) => seen.add(describe(s)));
      gate.dispose();

      async.elapse(const Duration(seconds: 1));
      gate.receive(const TurnCompleteSignal());
      expect(seen, ['audio']);
    });
  });
}
