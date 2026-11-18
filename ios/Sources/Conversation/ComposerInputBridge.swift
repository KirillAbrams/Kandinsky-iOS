// Согласует текст черновика с полем на айфоне. Следит, чтобы запись из модели не мешала
// незавершённому вводу клавиатуры.

import UIKit

@MainActor enum ComposerInputBridge {
  // Обновляет поле только при другом тексте и отсутствии незавершённого ввода. Иначе замена могла
  // бы прервать выбор текущего слова.
  static func synchronize(_ input: UITextView, to value: String) {
    guard input.markedTextRange == nil, input.text != value else { return }
    input.text = value
  }
  // Завершает отмеченный клавиатурой участок перед отправкой. Запрос получает текст без
  // незаконченного состояния ввода.
  static func finish(_ input: UITextView) { input.unmarkText() }
}
