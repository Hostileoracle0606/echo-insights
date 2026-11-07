import Flutter
import NaturalLanguage

/// Finds people, places and organisations in a piece of text with Apple's
/// NaturalLanguage name tagger, on the device. The text is not stored,
/// logged or sent anywhere. Dart side: lib/services/name_recognizer_channel.dart.
///
/// Channel `lumen/name_recognizer`: recognize {text} -> [{text, kind}] with
/// kind person | place | org.
enum NameRecognizer {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumen/name_recognizer", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "recognize" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any], let text = args["text"] as? String else {
        result(FlutterError(code: "name_recognizer", message: "bad args", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let names = recognize(text)
        DispatchQueue.main.async { result(names) }
      }
    }
  }

  static func recognize(_ text: String) -> [[String: String]] {
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
    var found: [[String: String]] = []
    tagger.enumerateTags(
      in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options
    ) { tag, range in
      let kind: String
      switch tag {
      case .personalName?: kind = "person"
      case .placeName?: kind = "place"
      case .organizationName?: kind = "org"
      default: return true
      }
      found.append(["text": String(text[range]), "kind": kind])
      return true
    }
    return found
  }
}
