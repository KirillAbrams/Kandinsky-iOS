import UIKit
private final class SessionWindow: UIWindow {
  var userInteraction: (() -> Void)?

  override func sendEvent(_ event: UIEvent) {
    if event.type == .presses || event.allTouches?.contains(where: {
      $0.phase == .began || $0.phase == .ended
    }) == true {
      userInteraction?()
    }
    super.sendEvent(event)
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var coordinator: AppCoordinator?
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = SessionWindow(windowScene: scene)
    window.userInteraction = { [weak self] in self?.coordinator?.userInteraction() }
    self.window = window
    coordinator = AppCoordinator(window: window)
    coordinator?.start(invitation: Self.invitation(options.urlContexts))
    window.makeKeyAndVisible()
  }
  private static func invitation(_ contexts: Set<UIOpenURLContext>) -> String? {
    guard let url = contexts.first?.url, url.scheme == "kandinsky-native", url.host == "join" else {
      return nil
    }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
      $0.name == "invitation"
    }?.value
  }
  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    guard let invitation = Self.invitation(contexts), let window else { return }
    coordinator?.close()
    coordinator = AppCoordinator(window: window)
    coordinator?.start(invitation: invitation)
  }
  func sceneDidBecomeActive(_ scene: UIScene) { coordinator?.graphicsVisible(true) }
  func sceneWillResignActive(_ scene: UIScene) { coordinator?.stopMedia() }
  func sceneDidEnterBackground(_ scene: UIScene) { coordinator?.background() }
}
