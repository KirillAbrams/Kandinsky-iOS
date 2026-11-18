// Этот элемент передаёт команду из режима озвучивания нарисованной кнопке. Им пользуется
// лента, где у видимого действия может не быть отдельной обычной кнопки.

import UIKit
@MainActor final class KandinskyActionElement: UIAccessibilityElement {
  var activate: (() -> Void)?
  // Вызываем назначенное действие и сообщаем системе, что касание принято. Без обработчика
  // возвращаем отказ, чтобы система не считала пустой элемент кнопкой.
  override func accessibilityActivate() -> Bool {
    guard let activate else { return false }
    activate()
    return true
  }
}
