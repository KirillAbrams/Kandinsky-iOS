import UIKit

@MainActor enum ComposerInputBridge {
  static func synchronize(_ input: UITextView, to value: String) {
    guard input.markedTextRange == nil, input.text != value else { return }
    input.text = value
  }
  /// Используется перед отправкой, чтобы поле больше не держало незавершённый участок ввода.
  static func finish(_ input: UITextView) { input.unmarkText() }
}
