import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneWillResignActive(_ scene: UIScene) {
    if let windowScene = scene as? UIWindowScene {
      PrivacyCover.shared.appWillResignActive(in: windowScene)
    }
    super.sceneWillResignActive(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    PrivacyCover.shared.appDidBecomeActive()
    super.sceneDidBecomeActive(scene)
  }
}
