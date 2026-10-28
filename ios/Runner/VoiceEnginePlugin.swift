import AVFoundation
import Flutter

/// One audio engine for the whole voice session. The mic (with Apple's voice
/// processing: echo cancellation, gain, noise suppression) and Lumen's voice
/// share it, so the echo canceller hears exactly what the speaker plays, and
/// playback is a queue of samples with nothing to open or wait on. Replaces
/// `record` (capture) and `just_audio` (playback).
///
/// Channels (Dart side: lib/audio/voice_engine.dart):
///   lumen/voice_engine      prepare · hasMicPermission · requestMicPermission
///                           · schedule {pcm, sampleRate} · stopPlayback
///   lumen/voice_engine/mic  16 kHz PCM16 mono chunks while listened to
final class VoiceEnginePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VoiceEnginePlugin()
    let methods = FlutterMethodChannel(
      name: "lumen/voice_engine", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    FlutterEventChannel(name: "lumen/voice_engine/mic", binaryMessenger: registrar.messenger())
      .setStreamHandler(instance)
  }

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  /// Lumen's voice as scheduled: Gemini's 24 kHz mono, float for the mixer.
  private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
  /// What Gemini expects from the mic.
  private let micFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
  private var attached = false
  private var voiceProcessing = false
  private var micSink: FlutterEventSink?
  private var playbackConverters: [Double: AVAudioConverter] = [:]

  static var micPermissionGranted: Bool {
    AVAudioSession.sharedInstance().recordPermission == .granted
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "prepare":
        try prepare()
        result(nil)
      case "hasMicPermission":
        result(Self.micPermissionGranted)
      case "requestMicPermission":
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async { result(granted) }
        }
      case "schedule":
        guard let args = call.arguments as? [String: Any],
          let pcm = args["pcm"] as? FlutterStandardTypedData,
          let rate = args["sampleRate"] as? NSNumber
        else {
          result(FlutterError(code: "voice_engine", message: "bad schedule args", details: nil))
          return
        }
        try schedule(pcm16: pcm.data, sampleRate: rate.doubleValue)
        result(nil)
      case "echoCancellation":
        // The Simulator accepts voice processing but cancels nothing: the
        // Mac's speakers reach the Mac's mic untouched.
        // On a device the mic stream turns voice processing on before its
        // first chunk and fails without it, so a mic that runs is cancelled.
        #if targetEnvironment(simulator)
          result(false)
        #else
          result(voiceProcessing || Self.micPermissionGranted)
        #endif
      case "stopPlayback":
        player.stop()
        if engine.isRunning { player.play() }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "voice_engine", message: "\(error)", details: nil))
    }
  }

  /// Audio session + running engine with the player attached. Idempotent and
  /// cheap once running; also restarts an engine iOS stopped (a call, Siri).
  private func prepare() throws {
    if attached && engine.isRunning { return }
    let session = AVAudioSession.sharedInstance()
    // .allowBluetooth is deprecated in the iOS 26 SDK (renamed
    // .allowBluetoothHFP) but is what iOS 16–25 understand.
    try session.setCategory(
      .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true)
    if !attached {
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
      attached = true
    }
    // Voice processing needs the mic. Turn it on only once permission
    // exists, so signing in never triggers the permission prompt.
    if Self.micPermissionGranted { try enableVoiceProcessing(restart: false) }
    engine.prepare()
    try engine.start()
    player.play()
  }

  /// Voice processing can only change while the engine is stopped.
  private func enableVoiceProcessing(restart: Bool) throws {
    guard !voiceProcessing else { return }
    let wasRunning = engine.isRunning
    if wasRunning { engine.stop() }
    try engine.inputNode.setVoiceProcessingEnabled(true)
    voiceProcessing = true
    if wasRunning && restart {
      engine.prepare()
      try engine.start()
      player.play()
    }
  }

  private func schedule(pcm16: Data, sampleRate: Double) throws {
    try prepare()
    guard let buffer = VoiceEngineDSP.floatBuffer(fromPCM16: pcm16, sampleRate: sampleRate)
    else { return }
    var playable = buffer
    if sampleRate != playbackFormat.sampleRate {
      let converter =
        playbackConverters[sampleRate]
        ?? AVAudioConverter(from: buffer.format, to: playbackFormat)!
      playbackConverters[sampleRate] = converter
      guard let converted = VoiceEngineDSP.convert(buffer, with: converter, to: playbackFormat)
      else { return }
      playable = converted
    }
    player.scheduleBuffer(playable, completionHandler: nil)
  }

  // MARK: mic stream

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    do {
      try prepare()
      try enableVoiceProcessing(restart: true)
      let input = engine.inputNode
      let inFormat = input.outputFormat(forBus: 0)
      guard
        let mono = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1),
        let converter = AVAudioConverter(from: mono, to: micFormat)
      else {
        return FlutterError(
          code: "voice_engine", message: "unsupported mic format \(inFormat)", details: nil)
      }
      micSink = events
      input.removeTap(onBus: 0)
      input.installTap(onBus: 0, bufferSize: 4800, format: inFormat) { [weak self] buffer, _ in
        guard let self,
          let chunk = VoiceEngineDSP.micChunk(
            from: buffer, monoFormat: mono, converter: converter, output: self.micFormat)
        else { return }
        DispatchQueue.main.async { self.micSink?(FlutterStandardTypedData(bytes: chunk)) }
      }
      return nil
    } catch {
      return FlutterError(code: "voice_engine", message: "\(error)", details: nil)
    }
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if voiceProcessing { engine.inputNode.removeTap(onBus: 0) }
    micSink = nil
    return nil
  }
}
