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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PrivacyCover") {
      PrivacyCover.shared.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FileProtection") {
      FileProtection.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NameRecognizer") {
      NameRecognizer.register(messenger: registrar.messenger())
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

/// Covers the window the moment the app stops being active, so the
/// app-switcher snapshot (taken after this) never shows journal text. Always
/// on, whether or not the app lock is.
///
/// On return the cover stays up when the app lock is on, until Dart says the
/// lock screen (or the content) has been built and presented, so the stale
/// frame the engine last drew can never show. Dart reports the lock's state
/// with `setLockEnabled`; until it has, the lock is assumed on (fails closed).
///
/// Channel `lumen/privacy` (Dart: lib/security/privacy_cover.dart):
///   setLockEnabled(bool) · releaseCover
///
/// If Dart never answers, after `holdLimit` the blur turns opaque and stays:
/// the app is wedged either way, and a blank screen leaks nothing, where
/// dropping the cover could reveal the stale journal frame. A late
/// `releaseCover` still lifts it, so a slow Dart recovers.
final class PrivacyCover {
  static let shared = PrivacyCover()
  private static let holdLimit: TimeInterval = 1.5

  private var lockActive = true
  private var active = true
  private var cover: UIVisualEffectView?
  /// The app is active again and the cover waits for Dart.
  private var held = false
  /// Dart released while the app was still inactive (a Face ID sheet closing
  /// can answer before the scene is active again).
  private var releasePending = false
  private var timer: Timer?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumen/privacy", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setLockEnabled":
        self?.lockActive = (call.arguments as? Bool) ?? true
        // The lock is off: nothing to wait for.
        if self?.lockActive == false { self?.release() }
        result(nil)
      case "releaseCover":
        self?.release()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func appWillResignActive(in scene: UIWindowScene) {
    active = false
    releasePending = false
    guard cover == nil,
      let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    else { return }
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    view.frame = window.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.accessibilityIdentifier = "privacyCover"
    window.addSubview(view)
    cover = view
  }

  func appDidBecomeActive() {
    active = true
    guard cover != nil else { return }
    if !lockActive || releasePending {
      remove()
      return
    }
    held = true
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.holdLimit, repeats: false) { [weak self] _ in
      self?.makeOpaque()
    }
  }

  private func release() {
    guard cover != nil else { return }
    if active { remove() } else { releasePending = true }
  }

  private func makeOpaque() {
    guard let cover else { return }
    cover.effect = nil
    cover.backgroundColor = UIColor(red: 0.973, green: 0.965, blue: 0.949, alpha: 1)
  }

  private func remove() {
    timer?.invalidate()
    timer = nil
    cover?.removeFromSuperview()
    cover = nil
    held = false
    releasePending = false
  }
}
