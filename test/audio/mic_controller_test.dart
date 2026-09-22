import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/mic_controller.dart';
import 'package:lumen/audio/pcm_capture.dart';

class _FakeCapture implements PcmCapture {
  final calls = <String>[];
  int failStarts = 0;

  @override
  Future<void> start(void Function(Uint8List pcm16) onChunk) async {
    calls.add('start');
    if (failStarts > 0) {
      failStarts--;
      throw StateError('audio session busy');
    }
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<bool> hasPermission() async => true;
}

AudioDevice _device({required bool input}) => AudioDevice(
      id: input ? 'mic' : 'speaker',
      name: input ? 'AirPods mic' : 'AirPods',
      isInput: input,
      isOutput: !input,
      // ignore: experimental_member_use
      type: AudioDeviceType.bluetoothA2dp,
    );

void main() {
  group('event mapping', () {
    test('interruption begin suspends', () {
      expect(
        micActionForInterruption(
            AudioInterruptionEvent(true, AudioInterruptionType.unknown)),
        MicAction.suspend,
      );
    });

    test('interruption end with shouldResume resumes', () {
      expect(
        micActionForInterruption(
            AudioInterruptionEvent(false, AudioInterruptionType.pause)),
        MicAction.resume,
      );
    });

    test('interruption end without shouldResume stays suspended', () {
      expect(
        micActionForInterruption(
            AudioInterruptionEvent(false, AudioInterruptionType.unknown)),
        MicAction.none,
      );
    });

    test('an input device appearing or disappearing restarts capture', () {
      expect(
        micActionForDevicesChanged(AudioDevicesChangedEvent(
          devicesAdded: {_device(input: true)},
          devicesRemoved: const {},
        )),
        MicAction.restart,
      );
      expect(
        micActionForDevicesChanged(AudioDevicesChangedEvent(
          devicesAdded: const {},
          devicesRemoved: {_device(input: true)},
        )),
        MicAction.restart,
      );
    });

    test('an output-only change leaves capture alone', () {
      expect(
        micActionForDevicesChanged(AudioDevicesChangedEvent(
          devicesAdded: {_device(input: false)},
          devicesRemoved: const {},
        )),
        MicAction.none,
      );
    });
  });

  group('MicController', () {
    late _FakeCapture capture;
    late List<String> order;
    late MicController mic;

    setUp(() {
      capture = _FakeCapture();
      order = capture.calls;
      mic = MicController(
        capture,
        (_) {},
        reactivate: () async => order.add('reactivate'),
      );
    });

    test('a phone call suspends and a resumable end resumes', () async {
      await mic.start();
      await mic.apply(MicAction.suspend);
      expect(mic.suspended, isTrue);
      await mic.apply(MicAction.resume);
      expect(mic.suspended, isFalse);
      expect(order, ['start', 'stop', 'reactivate', 'start']);
    });

    test('a failed resume stays suspended so it can be retried', () async {
      await mic.start();
      await mic.suspend();
      capture.failStarts = 1;
      await mic.resume();
      expect(mic.suspended, isTrue);
      await mic.resume();
      expect(mic.suspended, isFalse);
      expect(order, ['start', 'stop', 'reactivate', 'start', 'reactivate', 'start']);
    });

    test('route change restarts a running mic but not a suspended one',
        () async {
      await mic.start();
      await mic.restart();
      await mic.suspend();
      await mic.restart();
      expect(order, ['start', 'stop', 'start', 'stop']);
    });

    test('a failed restart does not wedge: it becomes resumable', () async {
      await mic.start();
      capture.failStarts = 1;
      await mic.restart();
      expect(mic.suspended, isTrue);
      await mic.resume();
      expect(mic.suspended, isFalse);
    });

    test('overlapping events run in order, never interleaved', () async {
      await mic.start();
      final pending = [mic.suspend(), mic.resume(), mic.restart()];
      await Future.wait(pending);
      expect(order, ['start', 'stop', 'reactivate', 'start', 'stop', 'start']);
    });

    test('stop wins over anything queued behind it', () async {
      await mic.start();
      final pending = [mic.suspend(), mic.stop(), mic.resume()];
      await Future.wait(pending);
      expect(order, ['start', 'stop']);
      expect(mic.suspended, isFalse);
    });

    test('resume without a prior suspend does nothing', () async {
      await mic.start();
      await mic.resume();
      expect(order, ['start']);
    });
  });
}
