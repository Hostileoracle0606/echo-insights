import 'dart:typed_data';

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
}
