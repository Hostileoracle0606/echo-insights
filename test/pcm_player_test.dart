import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/pcm_player.dart';

class _FakeBackend implements PcmAudioBackend {
  final streams = <Stream<List<int>>>[];
  int playCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> setAudioStream(Stream<List<int>> stream) async {
    streams.add(stream);
  }

  @override
  Future<void> play() async {
    playCalls += 1;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }
}

void main() {
  test('feed only queues audio and reports whether it was accepted', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    final pcm = Uint8List.fromList([1, 2, 3, 4]);

    expect(player.feed(pcm), isFalse);
    await player.init();

    final received = <List<int>>[];
    final subscription = backend.streams.single.listen(received.add);
    expect(player.feed(pcm), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.single.length, pcm.length + 44);
    await subscription.cancel();
    await player.dispose();
  });

  test('flush drops audio during reset and installs a fresh source', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    final pcm = Uint8List.fromList([1, 2]);
    await player.init();

    final flushing = player.flush();
    expect(player.feed(pcm), isFalse);
    await flushing;

    expect(backend.stopCalls, 1);
    expect(backend.playCalls, 2);
    expect(backend.streams, hasLength(2));
    expect(player.feed(pcm), isTrue);
    await player.dispose();
  });

  test('dispose rejects later audio and closes the backend', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();

    await player.dispose();

    expect(player.feed(Uint8List(2)), isFalse);
    expect(backend.disposeCalls, 1);
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
        final received = <List<int>>[];
        backend.streams.single.listen(received.add);

        expect(player.feed(ms(1000), audible: false), isTrue);
        async.flushMicrotasks();
        expect(received, isEmpty);
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

    test('WAV header carries the chunk sample rate', () {
      final wav = prependWavHeader(Uint8List(4), sampleRate: 24000);
      final header = ByteData.sublistView(wav, 0, 44);
      expect(header.getUint32(24, Endian.little), 24000);
      expect(header.getUint32(28, Endian.little), 48000);
    });
  });

  test('dispose is idempotent', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();
    await Future.wait([player.dispose(), player.dispose()]);
    expect(player.isDisposed, isTrue);
    expect(backend.disposeCalls, 1);
  });
}
