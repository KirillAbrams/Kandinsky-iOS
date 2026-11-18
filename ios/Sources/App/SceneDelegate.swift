// Связывает окно айфона и действия системы с управлением приложением. Здесь принимаются
// приглашения, отмечается активность и приостанавливается работа при уходе с экрана.

import UIKit
private final class SessionWindow: UIWindow {
  var userInteraction: (() -> Void)?

  // Отмечает нажатия и начало или конец касания как действия пользователя и передаёт событие
  // обычному оконному обработчику. Так движение пальца не вызывает лишних отметок, а кнопки
  // продолжают работать.
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
  // Создаёт окно, передаёт ему обработчик действий и запускает приложение с приглашением, если
  // система его передала. Затем делает окно видимым, чтобы показать начальный экран.
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
  // Принимает только ссылку на вход с ожидаемыми схемой и адресом, затем берёт поле приглашения.
  // Посторонняя ссылка не должна перезапускать приложение.
  private static func invitation(_ contexts: Set<UIOpenURLContext>) -> String? {
    guard let url = contexts.first?.url, url.scheme == "kandinsky-native", url.host == "join" else {
      return nil
    }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
      $0.name == "invitation"
    }?.value
  }
  // Обрабатывает подходящую ссылку при уже открытом окне. Закрывает прежний обработчик и начинает
  // запуск заново с полученным приглашением.
  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    guard let invitation = Self.invitation(contexts), let window else { return }
    coordinator?.close()
    coordinator = AppCoordinator(window: window)
    coordinator?.start(invitation: invitation)
  }
  // Сообщает, что окно снова активно и отрисовку можно продолжить. Без этого приложение могло бы
  // остаться в режиме скрытого окна.
  func sceneDidBecomeActive(_ scene: UIScene) { coordinator?.graphicsVisible(true) }
  // Останавливает проигрывание, когда окно теряет активность. Звук и видео не должны продолжать
  // работу за системным экраном.
  func sceneWillResignActive(_ scene: UIScene) { coordinator?.stopMedia() }
  // Передаёт уход в фон обработчику приложения. Он может остановить активную работу и сохранить
  // необходимое для возвращения состояние.
  func sceneDidEnterBackground(_ scene: UIScene) { coordinator?.background() }
}
