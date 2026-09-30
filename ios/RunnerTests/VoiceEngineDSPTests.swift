import AVFoundation
import XCTest
@testable import Runner

final class VoiceEngineDSPTests: XCTestCase {
  func testPCM16BecomesFloatInRange() {
    let samples: [Int16] = [0, 16384, -32768, 32767]
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let buffer = VoiceEngineDSP.floatBuffer(fromPCM16: data, sampleRate: 24_000)!
    XCTAssertEqual(buffer.frameLength, 4)
    XCTAssertEqual(buffer.format.sampleRate, 24_000)
    let out = buffer.floatChannelData![0]
    XCTAssertEqual(out[0], 0)
    XCTAssertEqual(out[1], 0.5, accuracy: 1e-4)
    XCTAssertEqual(out[2], -1)
    XCTAssertEqual(out[3], 1, accuracy: 1e-4)
  }

  func testEmptyPCMIsNothingToSchedule() {
    XCTAssertNil(VoiceEngineDSP.floatBuffer(fromPCM16: Data(), sampleRate: 24_000))
  }

  func testResamplesToThePlaybackRate() {
    let tone = [Int16](repeating: 8192, count: 1600)  // 100 ms at 16 kHz
    let data = tone.withUnsafeBufferPointer { Data(buffer: $0) }
    let input = VoiceEngineDSP.floatBuffer(fromPCM16: data, sampleRate: 16_000)!
    let target = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    let converter = AVAudioConverter(from: input.format, to: target)!
    let out = VoiceEngineDSP.convert(input, with: converter, to: target)!
    XCTAssertEqual(Double(out.frameLength), 2400, accuracy: 48)  // 100 ms at 24 kHz
  }

  func testMicChunksAre16kHzPCM16FromTheFirstChannelWithNothingLost() {
    // 100 ms taps at 48 kHz, two channels, as voice processing may report them.
    let tapFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let output = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let converter = AVAudioConverter(from: mono, to: output)!
    func tap() -> AVAudioPCMBuffer {
      let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: 4800)!
      buffer.frameLength = 4800
      for i in 0..<4800 {
        buffer.floatChannelData![0][i] = 0.25
        buffer.floatChannelData![1][i] = -0.9
      }
      return buffer
    }

    let chunks = (0..<20).map { _ in
      VoiceEngineDSP.micChunk(from: tap(), monoFormat: mono, converter: converter, output: output)!
    }

    // The resampler holds back up to ~250 samples of filter history and
    // releases it over later chunks (so chunk sizes vary), but the stream
    // never drifts: after 2 s of taps the output is 2 s of 16 kHz audio
    // (32,000 samples × 2 B) less at most 256 samples still in the
    // converter — never more than went in.
    let total = chunks.reduce(0) { $0 + $1.count }
    XCTAssertLessThanOrEqual(total, 64_000)
    XCTAssertGreaterThanOrEqual(total, 64_000 - 512)
    for chunk in chunks {
      XCTAssertGreaterThan(chunk.count, 0)
      XCTAssertLessThanOrEqual(chunk.count, 3232, "at most one output buffer per tap")
    }
    let middle = chunks[10].withUnsafeBytes {
      $0.load(fromByteOffset: (chunks[10].count / 2) & ~1, as: Int16.self)
    }
    XCTAssertEqual(Double(middle) / 32768, 0.25, accuracy: 0.02, "channel 0 carries the voice")
  }
}
