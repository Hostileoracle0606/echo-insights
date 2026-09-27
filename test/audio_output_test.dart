import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/audio/pcm_player.dart';

class _Backend implements PcmAudioBackend {
  _Backend({this.stallPlay = false});

  final bool stallPlay;
  int disposeCalls = 0;

  @override
  Future<void> setAudioStream(Stream<List<int>> stream) async {}

  @override
  Future<void> play() => stallPlay ? Completer<void>().future : Future.value();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async => disposeCalls += 1;
}

void main() {
  test('initialises one player and reuses it for every session', () async {
    final backends = <_Backend>[];
    var prepared = 0;
    final output = AudioOutput(
      prepare: () async => prepared += 1,
      createPlayer: () {
        final backend = _Backend();
        backends.add(backend);
        return PcmPlayer(backend: backend);
      },
    );

    final results = await Future.wait([output.start(), output.start()]);
    final again = await output.whenReady();

    expect(backends, hasLength(1));
    expect(prepared, 1);
    expect(results[0], same(results[1]));
    expect(again, same(results[0]));
    expect(output.player, same(again));
  });

  test('a stalled init never blocks a session and is retried later', () {
    fakeAsync((async) {
      var stall = true;
      final backends = <_Backend>[];
      final output = AudioOutput(
        createPlayer: () {
          final backend = _Backend(stallPlay: stall);
          backends.add(backend);
          return PcmPlayer(backend: backend);
        },
      );

      output.start();
      Object? waited = 'pending';
      output
          .whenReady(timeout: const Duration(seconds: 1))
          .then((value) => waited = value);
      async.elapse(const Duration(seconds: 1));
      expect(waited, isNull, reason: 'the session gave up after 1 s');
      expect(output.player, isNull);

      async.elapse(const Duration(seconds: 5));
      expect(output.player, isNull, reason: 'init timed out and was dropped');

      stall = false;
      PcmPlayer? retried;
      output.start().then((value) => retried = value);
      async.flushMicrotasks();
      expect(retried, isNotNull);
      expect(backends, hasLength(2));
    });
  });

  test('sign-out disposes the player; sign-in starts a fresh one', () async {
    final backends = <_Backend>[];
    final output = AudioOutput(
      createPlayer: () {
        final backend = _Backend();
        backends.add(backend);
        return PcmPlayer(backend: backend);
      },
    );

    final first = await output.start();
    await output.stop();
    expect(first!.isDisposed, isTrue);
    expect(backends.single.disposeCalls, 1);
    expect(output.player, isNull);

    final second = await output.start();
    expect(second, isNot(same(first)));
    expect(backends, hasLength(2));
  });

  test('a start abandoned by sign-out does not come back as the player',
      () async {
    final gate = Completer<void>();
    final output = AudioOutput(
      prepare: () => gate.future,
      createPlayer: () => PcmPlayer(backend: _Backend()),
    );

    final starting = output.start();
    await output.stop();
    gate.complete();

    expect(await starting, isNull);
    expect(output.player, isNull);
  });
}
