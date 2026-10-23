import AVFoundation

/// Sample conversions for the voice engine. Pure, so they can be unit-tested
/// without an audio session.
enum VoiceEngineDSP {
  /// PCM16 little-endian mono → a float mono buffer at `sampleRate`.
  static func floatBuffer(fromPCM16 data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
    let frames = data.count / 2
    guard frames > 0,
      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    let out = buffer.floatChannelData![0]
    data.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
    }
    return buffer
  }

  /// Converts `buffer` into a new buffer of `format`. The converter keeps its
  /// state between calls, so streaming audio resamples without seams.
  static func convert(
    _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if consumed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    return status == .error ? nil : out
  }

  /// A mic tap buffer (hardware rate, any channel count) → 16 kHz PCM16 mono
  /// bytes. Voice processing may report several input channels; the first
  /// carries the processed voice.
  static func micChunk(
    from buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat,
    converter: AVAudioConverter, output: AVAudioFormat
  ) -> Data? {
    guard let source = buffer.floatChannelData,
      let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength)
    else { return nil }
    mono.frameLength = buffer.frameLength
    mono.floatChannelData![0].update(from: source[0], count: Int(buffer.frameLength))
    guard let out = convert(mono, with: converter, to: output), out.frameLength > 0 else {
      return nil
    }
    return Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * 2)
  }
}
