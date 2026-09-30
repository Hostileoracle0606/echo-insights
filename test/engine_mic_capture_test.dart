// The mic through the shared voice engine (echo cancellation hears Lumen).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/voice_engine.dart';

class _FakeEngine extends VoiceEngine {
  _FakeEngine({this.granted = true, this.grantOnRequest = true});
  final bool granted;
  final bool grantOnRequest;
  int requests = 0;
  final mic = StreamController<Uint8List>.broadcast();

  @override
  Future<bool> hasMicPermission() async => granted;

  @override
  Future<bool> requestMicPermission() async {
    requests += 1;
    return grantOnRequest;
  }

  @override
  Stream<Uint8List> micChunks() => mic.stream;
}

void main() {
  test('forwards mic chunks in order', () async {
    final engine = _FakeEngine();
    final capture = EngineMicCapture(engine);
    final got = <List<int>>[];
    await capture.start((pcm) => got.add(pcm.toList()));
    engine.mic
      ..add(Uint8List.fromList([1, 1]))
      ..add(Uint8List.fromList([2, 2]));
    await Future<void>.delayed(Duration.zero);
    expect(got, [
      [1, 1],
      [2, 2],
    ]);
    await capture.stop();
  });

  test('stop ends the stream (the native tap is removed)', () async {
    final engine = _FakeEngine();
    final capture = EngineMicCapture(engine);
    await capture.start((_) {});
    expect(engine.mic.hasListener, isTrue);
    await capture.stop();
    expect(engine.mic.hasListener, isFalse);
  });

  test('starting again does not deliver chunks twice', () async {
    final engine = _FakeEngine();
    final capture = EngineMicCapture(engine);
    var count = 0;
    await capture.start((_) => count += 1);
    await capture.start((_) => count += 1);
    engine.mic.add(Uint8List(2));
    await Future<void>.delayed(Duration.zero);
    expect(count, 1);
    await capture.stop();
  });

  test('permission already granted: no prompt', () async {
    final engine = _FakeEngine();
    expect(await EngineMicCapture(engine).hasPermission(), isTrue);
    expect(engine.requests, 0);
  });

  test('permission not yet granted: prompts and returns the answer', () async {
    final engine = _FakeEngine(granted: false, grantOnRequest: false);
    expect(await EngineMicCapture(engine).hasPermission(), isFalse);
    expect(engine.requests, 1);
  });
}
