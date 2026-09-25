// Lumen's greeting is a bundled clip played locally on every session start,
// so Gemini never has to generate (and bill) an opening.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/standard_opening.dart';
import 'package:lumen/logic/conversation_policy.dart';

Uint8List wav({int rate = 24000, int channels = 1, int bits = 16, int samples = 4}) {
  final pcm = Uint8List(samples * channels * bits ~/ 8);
  final b = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * channels * bits ~/ 8, Endian.little);
  b.setUint16(32, channels * bits ~/ 8, Endian.little);
  b.setUint16(34, bits, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, pcm.length, Endian.little);
  return Uint8List.fromList([...b.buffer.asUint8List(), ...pcm]);
}

void main() {
  test('parses PCM16 mono WAV into samples and rate', () {
    final clip = parsePcm16Wav(wav(rate: 24000, samples: 10));
    expect(clip.sampleRate, 24000);
    expect(clip.pcm.length, 20);
  });

  test('rejects audio the player cannot play as-is', () {
    expect(() => parsePcm16Wav(wav(channels: 2)), throwsFormatException);
    expect(() => parsePcm16Wav(wav(bits: 8)), throwsFormatException);
    expect(() => parsePcm16Wav(Uint8List(10)), throwsFormatException);
  });

  test('splits the clip into short chunks for smooth streaming', () {
    final clip = StandardOpening(
      text: 'Hi',
      pcm: Uint8List(24000 * 2), // 1s at 24kHz
      sampleRate: 24000,
    );
    final chunks = clip.chunks(const Duration(milliseconds: 250)).toList();
    expect(chunks, hasLength(4));
    expect(chunks.fold<int>(0, (n, c) => n + c.length), 48000);
    expect(clip.duration, const Duration(seconds: 1));
  });

  test('the bundled greeting is a short 24kHz clip with matching words', () {
    final text = File('assets/audio/lumen_opening.txt').readAsStringSync().trim();
    final parsed =
        parsePcm16Wav(File('assets/audio/lumen_opening.wav').readAsBytesSync());
    final clip = StandardOpening(
      text: text,
      pcm: parsed.pcm,
      sampleRate: parsed.sampleRate,
    );
    expect(text, isNotEmpty);
    expect(clip.sampleRate, 24000);
    // Long enough to be real speech, short enough not to hold the floor.
    expect(clip.duration, greaterThan(const Duration(seconds: 1)));
    expect(clip.duration, lessThan(const Duration(seconds: 6)));
  });

  test('Gemini is told the exact greeting the app plays', () {
    // If these drift, Gemini believes it said something the user never heard.
    final text = File('assets/audio/lumen_opening.txt').readAsStringSync().trim();
    expect(geminiLiveSystemInstruction, contains('saying exactly: "$text"'));
  });
}
