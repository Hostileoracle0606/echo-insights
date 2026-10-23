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
  }
}
