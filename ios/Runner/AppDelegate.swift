import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The app's own voice engine (mic + Lumen's voice on one AVAudioEngine).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VoiceEnginePlugin") {
      VoiceEnginePlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FileProtection") {
      FileProtection.register(messenger: registrar.messenger())
    }
  }
}

/// Data-protection class of the files the app writes (Dart side:
/// lib/security/file_protection.dart). The `default-data-protection`
/// entitlement covers files created by default; this sets a class on a file
/// explicitly and reads one back for verification.
///
/// Channel `lumen/file_protection`: set {path, level} · get {path}
enum FileProtection {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumen/file_protection", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "file_protection", message: "bad args", details: nil))
        return
      }
      do {
        switch call.method {
        case "set":
          let level: FileProtectionType =
            (args["level"] as? String) == "completeUnlessOpen" ? .completeUnlessOpen : .complete
          try FileManager.default.setAttributes([.protectionKey: level], ofItemAtPath: path)
          result(nil)
        case "get":
          let attributes = try FileManager.default.attributesOfItem(atPath: path)
          result((attributes[.protectionKey] as? FileProtectionType)?.rawValue)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "file_protection", message: "\(error)", details: nil))
      }
    }
  }
}
