import 'package:flutter/services.dart';

import '../logic/pseudonym/fake_names.dart';
import '../logic/pseudonym/name_recognizer.dart';

/// Apple's NaturalLanguage name recognition (`NLTagger`, name type), on the
/// device: ios/Runner/NameRecognizer.swift. The text never leaves the phone.
///
/// Channel `lumen/name_recognizer`: recognize {text} ->
/// [{text, kind: person|place|org}]
class NativeNameRecognizer implements NameRecognizer {
  NativeNameRecognizer([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel('lumen/name_recognizer');
  final MethodChannel _channel;

  @override
  Future<List<RecognizedName>> recognize(String text) async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'recognize',
      {'text': text},
    );
    final out = <RecognizedName>[];
    for (final item in raw ?? const <Map<Object?, Object?>>[]) {
      final name = item['text'];
      final kind = switch (item['kind']) {
        'person' => PseudonymKind.person,
        'place' => PseudonymKind.place,
        'org' => PseudonymKind.org,
        _ => null,
      };
      if (name is String && kind != null) out.add(RecognizedName(name, kind));
    }
    return out;
  }
}
