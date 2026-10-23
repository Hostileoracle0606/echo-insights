// The Dart side of the native voice engine: what goes over each channel.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/voice_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('lumen/voice_engine');
  const mic = EventChannel('lumen/voice_engine/mic');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'hasMicPermission' => true,
        'requestMicPermission' => false,
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(mic, null);
  });

  test('schedule sends raw PCM and its rate — no WAV header', () async {
    await VoiceEngine().schedule(Uint8List.fromList([1, 2, 3, 4]), 24000);
    expect(calls.single.method, 'schedule');
    expect(calls.single.arguments, {
      'pcm': Uint8List.fromList([1, 2, 3, 4]),
      'sampleRate': 24000,
    });
  });

  test('prepare and stopPlayback are plain calls', () async {
    final engine = VoiceEngine();
    await engine.prepare();
    await engine.stopPlayback();
    expect(calls.map((c) => c.method), ['prepare', 'stopPlayback']);
  });

  test('permission answers come from the native side', () async {
    final engine = VoiceEngine();
    expect(await engine.hasMicPermission(), isTrue);
    expect(await engine.requestMicPermission(), isFalse);
  });

  test('mic chunks stream while listened to and stop on cancel', () async {
    var cancelled = false;
    messenger.setMockStreamHandler(
      mic,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          events.success(Uint8List.fromList([7, 7]));
        },
        onCancel: (arguments) => cancelled = true,
      ),
    );
    final chunks = <Uint8List>[];
    final sub = VoiceEngine().micChunks().listen(chunks.add);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(chunks, [
      [7, 7],
    ]);
    expect(cancelled, isTrue);
  });

  test('a native failure surfaces as a PlatformException', () async {
    messenger.setMockMethodCallHandler(
      methods,
      (_) async =>
          throw PlatformException(code: 'voice_engine', message: 'no route'),
    );
    await expectLater(
      VoiceEngine().prepare(),
      throwsA(isA<PlatformException>()),
    );
  });
}
