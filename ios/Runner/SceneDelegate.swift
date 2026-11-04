import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// Covers the window the moment the app stops being active, so the
  /// app-switcher snapshot (taken after this) never shows journal text. Runs
  /// whether or not the app lock is on.
  private var privacyCover: UIVisualEffectView?

  override func sceneWillResignActive(_ scene: UIScene) {
    if let windowScene = scene as? UIWindowScene,
      let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
      privacyCover == nil
    {
      let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
      cover.frame = window.bounds
      cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      cover.accessibilityIdentifier = "privacyCover"
      window.addSubview(cover)
      privacyCover = cover
    }
    super.sceneWillResignActive(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    privacyCover?.removeFromSuperview()
    privacyCover = nil
    super.sceneDidBecomeActive(scene)
  }
}
