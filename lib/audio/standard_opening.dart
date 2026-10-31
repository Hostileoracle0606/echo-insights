import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Lumen's greeting, bundled with the app and played locally at the start of
/// every session. Gemini Live is told the greeting was already said, so it
/// never has to generate (and bill for) an opening.
///
/// The words live in assets/audio/lumen_opening.txt; the audio in
/// assets/audio/lumen_opening.wav is generated from them in Lumen's Gemini
/// voice by tool/generate_opening_audio.mjs.
class StandardOpening {
  const StandardOpening({
    required this.text,
    required this.pcm,
    required this.sampleRate,
  });

  static const textAsset = 'assets/audio/lumen_opening.txt';
  static const audioAsset = 'assets/audio/lumen_opening.wav';

  /// The shorter hello for someone who has been here before.
  static const returningTextAsset = 'assets/audio/lumen_returning.txt';
  static const returningAudioAsset = 'assets/audio/lumen_returning.wav';

  final String text;

  /// PCM16 mono samples.
  final Uint8List pcm;
  final int sampleRate;

  Duration get duration =>
      Duration(microseconds: (pcm.length / 2 / sampleRate * 1e6).round());

  static Future<StandardOpening> load(AssetBundle bundle) =>
      _load(bundle, textAsset, audioAsset);

  static Future<StandardOpening> loadReturning(AssetBundle bundle) =>
      _load(bundle, returningTextAsset, returningAudioAsset);

  static Future<StandardOpening> _load(
    AssetBundle bundle,
    String textPath,
    String audioPath,
  ) async {
    final text = (await bundle.loadString(textPath)).trim();
    final wav = await bundle.load(audioPath);
    final clip = parsePcm16Wav(wav.buffer.asUint8List(
      wav.offsetInBytes,
      wav.lengthInBytes,
    ));
    return StandardOpening(
      text: text,
      pcm: clip.pcm,
      sampleRate: clip.sampleRate,
    );
  }

  /// The clip in [every]-long pieces, so it streams like Gemini audio
  /// instead of arriving as one large WAV.
  Iterable<Uint8List> chunks(Duration every) sync* {
    final step = (sampleRate * every.inMicroseconds / 1e6).round() * 2;
    for (var at = 0; at < pcm.length; at += step) {
      yield Uint8List.sublistView(
        pcm,
        at,
        at + step > pcm.length ? pcm.length : at + step,
      );
    }
  }
}

/// Extracts the samples from a PCM16 mono WAV, walking its chunks rather
/// than assuming a 44-byte header.
({Uint8List pcm, int sampleRate}) parsePcm16Wav(Uint8List bytes) {
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('Not a WAV file');
  }
  final data = ByteData.sublistView(bytes);
  int? rate;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final id = tag(at);
    final size = data.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (id == 'fmt ') {
      final format = data.getUint16(body, Endian.little);
      final channels = data.getUint16(body + 2, Endian.little);
      final bits = data.getUint16(body + 14, Endian.little);
      if (format != 1 || channels != 1 || bits != 16) {
        throw FormatException(
            'Expected PCM16 mono, got format=$format channels=$channels bits=$bits');
      }
      rate = data.getUint32(body + 4, Endian.little);
    } else if (id == 'data') {
      if (rate == null) throw const FormatException('WAV data before fmt');
      final end = body + size > bytes.length ? bytes.length : body + size;
      return (pcm: Uint8List.sublistView(bytes, body, end), sampleRate: rate);
    }
    at = body + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('WAV has no data chunk');
}
