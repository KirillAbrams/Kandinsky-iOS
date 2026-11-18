import UIKit
@MainActor final class KandinskyActionElement: UIAccessibilityElement {
  var activate: (() -> Void)?
  override func accessibilityActivate() -> Bool {
    guard let activate else { return false }
    activate()
    return true
  }
}
