import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/pcm_player.dart';

class _FakeBackend implements PcmAudioBackend {
  final scheduled = <(List<int>, int)>[];
  int starts = 0;
  int stops = 0;
  int disposes = 0;

  @override
  Future<void> start() async => starts += 1;

  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) async =>
      scheduled.add((pcm16.toList(), sampleRate));

  @override
  Future<void> stop() async => stops += 1;

  @override
  Future<void> dispose() async => disposes += 1;
}

void main() {
  test('init never waits for audio (the on-device 5 s timeout)', () async {
    final player = PcmPlayer(backend: _FakeBackend());
    // The just_audio backend blocked here until audio arrived, which could
    // only happen after init: on the device it always hit the 5 s timeout.
    await player.init().timeout(const Duration(milliseconds: 100));
    expect(player.feed(Uint8List(4)), isTrue);
    await player.dispose();
  });

  test('feed before init is refused', () {
    final player = PcmPlayer(backend: _FakeBackend());
    expect(player.feed(Uint8List(4)), isFalse);
  });

  test('feed schedules the raw PCM at its rate, in order', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();
    player
      ..feed(Uint8List.fromList([1, 2]))
      ..feed(Uint8List.fromList([3, 4]), sampleRate: 16000);
    await Future<void>.delayed(Duration.zero);
    // Compared as plain lists: a record holding a List compares it by
    // identity.
    expect(backend.scheduled.map((e) => e.$1).toList(), [
      [1, 2],
      [3, 4],
    ]);
    expect(backend.scheduled.map((e) => e.$2).toList(), [24000, 16000]);
    await player.dispose();
  });

  test('flush drops queued audio and stays ready', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();
    player.feed(Uint8List(48000));
    await player.flush();
    expect(backend.stops, 1);
    expect(player.speaking.value, isFalse);
    expect(player.feed(Uint8List(4)), isTrue);
    await player.dispose();
  });

  test('dispose rejects later audio and releases the backend', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();
    await player.dispose();
    expect(player.feed(Uint8List(2)), isFalse);
    expect(backend.disposes, 1);
  });

  group('playback clock', () {
    // One second of 24kHz mono PCM16 is 48,000 bytes.
    Uint8List ms(int millis, {int rate = 24000}) =>
        Uint8List(rate * 2 * millis ~/ 1000);

    test('speaks for the duration of the audio fed, not its arrival', () {
      fakeAsync((async) {
        final player = PcmPlayer(backend: _FakeBackend(), now: () => async.elapsed);
        player.init();
        async.flushMicrotasks();

        // Gemini streams faster than real time: 3s of audio lands at once.
        for (var i = 0; i < 3; i++) {
          player.feed(ms(1000));
        }
        expect(player.speaking.value, isTrue);
        expect(player.remaining, const Duration(seconds: 3));

        async.elapse(const Duration(milliseconds: 2900));
        expect(player.speaking.value, isTrue, reason: 'audio still queued');

        async.elapse(const Duration(milliseconds: 200));
        expect(player.speaking.value, isFalse);
        expect(player.remaining, Duration.zero);
        player.dispose();
        async.flushMicrotasks();
      });
    });

    test('a gap longer than the queue restarts the clock from now', () {
      fakeAsync((async) {
        final player = PcmPlayer(backend: _FakeBackend(), now: () => async.elapsed);
        player.init();
        async.flushMicrotasks();

        player.feed(ms(500));
        async.elapse(const Duration(seconds: 2));
        expect(player.speaking.value, isFalse);

        player.feed(ms(500));
        expect(player.remaining, const Duration(milliseconds: 500));
        player.dispose();
        async.flushMicrotasks();
      });
    });

    test('honours the chunk sample rate', () {
      fakeAsync((async) {
        final player = PcmPlayer(backend: _FakeBackend(), now: () => async.elapsed);
        player.init();
        async.flushMicrotasks();

        player.feed(ms(1000, rate: 16000), sampleRate: 16000);
        expect(player.remaining, const Duration(seconds: 1));
        player.dispose();
        async.flushMicrotasks();
      });
    });

    test('silent audio advances the clock without reaching the speaker', () {
      fakeAsync((async) {
        final backend = _FakeBackend();
        final player = PcmPlayer(backend: backend, now: () => async.elapsed);
        player.init();
        async.flushMicrotasks();

        expect(player.feed(ms(1000), audible: false), isTrue);
        async.flushMicrotasks();
        expect(backend.scheduled, isEmpty);
        expect(player.speaking.value, isTrue);
        player.dispose();
        async.flushMicrotasks();
      });
    });

    test('flush stops speaking immediately', () {
      fakeAsync((async) {
        final player = PcmPlayer(backend: _FakeBackend(), now: () => async.elapsed);
        player.init();
        async.flushMicrotasks();

        player.feed(ms(3000));
        player.flush();
        expect(player.speaking.value, isFalse);
        expect(player.remaining, Duration.zero);
        async.flushMicrotasks();
        player.dispose();
        async.flushMicrotasks();
      });
    });

  });

  test('dispose is idempotent', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();
    await Future.wait([player.dispose(), player.dispose()]);
    expect(player.isDisposed, isTrue);
    expect(backend.disposes, 1);
  });
}
