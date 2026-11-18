// Точка входа айфона. Передаёт создание окна обработчику сцены, которому принадлежат показ и
// смена состояния приложения.

import UIKit
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
  // Возвращает описание сцены и назначает её обработчик. Полученное от системы окно будет
  // настроено тем же способом и при следующем подключении сцены.
  func application(
    _ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Main", sessionRole: session.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}
