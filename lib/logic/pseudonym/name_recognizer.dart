import 'fake_names.dart';

/// A name the recognizer found in a piece of text.
class RecognizedName {
  const RecognizedName(this.text, this.kind);
  final String text;
  final PseudonymKind kind;
}

/// Finds names in free text, on the device (Apple NaturalLanguage on iOS:
/// lib/services/name_recognizer_channel.dart). The map learns people, places
/// and organisations it has not seen in the user's graph from it. Tests
/// inject a fake.
///
/// May throw; callers treat a failure as "no names found" and carry on with
/// the names they already know.
abstract interface class NameRecognizer {
  Future<List<RecognizedName>> recognize(String text);
}
