import 'package:flutter/services.dart';

import 'audio_route.dart';

/// Dart side of the native voice engine (ios/Runner/VoiceEnginePlugin.swift):
/// one AVAudioEngine that records the mic with Apple voice processing and
/// plays Lumen's voice, so echo cancellation hears what the speaker plays.
class VoiceEngine {
  VoiceEngine({
    MethodChannel? methods,
    EventChannel? mic,
    EventChannel? route,
  })  : _methods = methods ?? const MethodChannel('lumen/voice_engine'),
        _mic = mic ?? const EventChannel('lumen/voice_engine/mic'),
        _route = route ?? const EventChannel('lumen/voice_engine/route');

  static final instance = VoiceEngine();

  final MethodChannel _methods;
  final EventChannel _mic;
  final EventChannel _route;

  /// Audio session and running engine. Idempotent; also recovers an engine
  /// iOS stopped (a phone call, Siri).
  Future<void> prepare() => _methods.invokeMethod<void>('prepare');

  Future<bool> hasMicPermission() async =>
      await _methods.invokeMethod<bool>('hasMicPermission') ?? false;

  /// Shows the system prompt if the user hasn't answered yet.
  Future<bool> requestMicPermission() async =>
      await _methods.invokeMethod<bool>('requestMicPermission') ?? false;

  /// Queues one PCM16 mono chunk behind everything already queued. Platform
  /// messages are delivered in order, so chunks play in the order sent.
  Future<void> schedule(Uint8List pcm16, int sampleRate) =>
      _methods.invokeMethod<void>(
        'schedule',
        {'pcm': pcm16, 'sampleRate': sampleRate},
      );

  /// Whether Apple's echo cancellation removes Lumen's voice from the mic:
  /// true on a device once voice processing is on, never on the Simulator.
  Future<bool> echoCancellation() async =>
      await _methods.invokeMethod<bool>('echoCancellation') ?? false;

  /// Drops everything queued; the engine keeps running.
  Future<void> stopPlayback() => _methods.invokeMethod<void>('stopPlayback');

  /// 16 kHz PCM16 mono mic audio, while listened to.
  Stream<Uint8List> micChunks() =>
      _mic.receiveBroadcastStream().map((chunk) => chunk as Uint8List);

  /// Where sound is going now.
  Future<AudioRoute> outputRoute() async => AudioRoute.parse(
        await _methods.invokeMethod<String>('outputRoute'),
      );

  /// The current output route, then each change (headphones plugged in or
  /// out, Bluetooth connecting).
  Stream<AudioRoute> routeChanges() =>
      _route.receiveBroadcastStream().map(AudioRoute.parse);
}
