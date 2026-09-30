import 'package:flutter/services.dart';

/// Dart side of the native voice engine (ios/Runner/VoiceEnginePlugin.swift):
/// one AVAudioEngine that records the mic with Apple voice processing and
/// plays Lumen's voice, so echo cancellation hears what the speaker plays.
class VoiceEngine {
  VoiceEngine({MethodChannel? methods, EventChannel? mic})
      : _methods = methods ?? const MethodChannel('lumen/voice_engine'),
        _mic = mic ?? const EventChannel('lumen/voice_engine/mic');

  static final instance = VoiceEngine();

  final MethodChannel _methods;
  final EventChannel _mic;

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

  /// Drops everything queued; the engine keeps running.
  Future<void> stopPlayback() => _methods.invokeMethod<void>('stopPlayback');

  /// 16 kHz PCM16 mono mic audio, while listened to.
  Stream<Uint8List> micChunks() =>
      _mic.receiveBroadcastStream().map((chunk) => chunk as Uint8List);
}
