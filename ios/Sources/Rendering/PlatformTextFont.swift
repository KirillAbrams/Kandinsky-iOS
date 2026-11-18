// Здесь выбираются и переиспользуются системные шрифты на айфоне. Для некоторых образов имитатора
// отдельно сохраняем цветные составные значки, чтобы результат ввода соответствовал реальному
// телефону.

import CoreText
import Foundation
import UIKit

enum PlatformTextFont {
  #if targetEnvironment(simulator)

    private static let emojiDescriptor: CTFontDescriptor? = {
      guard let root = ProcessInfo.processInfo.environment["SIMULATOR_ROOT"] else { return nil }
      let url = URL(fileURLWithPath: root).appendingPathComponent(
        "System/Library/Fonts/CoreAddition/AppleColorEmoji-160px.ttc")
      guard FileManager.default.fileExists(atPath: url.path),
        let faces = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
      else { return nil }
      return faces.first
    }()
  #endif
  private static let uiCache: NSCache<NSString, UIFont> = {
    let c = NSCache<NSString, UIFont>()
    c.countLimit = 32
    return c
  }()
  // Повторно используем сочетание размера и начертания. В имитаторе добавляем рабочий шрифт
  // цветных значков, сохраняя остальную подстановку системных букв.
  static func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
    let key = "\(size):\(weight.rawValue)" as NSString
    if let cached = uiCache.object(forKey: key) { return cached }
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    #if targetEnvironment(simulator)
      if let emojiDescriptor {
        let defaults =
          CTFontCopyDefaultCascadeListForLanguages(base as CTFont, nil) as? [CTFontDescriptor] ?? []
        let descriptors =
          [emojiDescriptor]
          + defaults.filter {
            let name = CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String ?? ""
            return !name.lowercased().contains("emoji")
          }
        let attributes = CTFontDescriptorCreateWithAttributes(
          [kCTFontCascadeListAttribute: descriptors] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base as CTFont, size, nil, attributes) as UIFont
        uiCache.setObject(font, forKey: key)
        return font
      }
    #endif
    uiCache.setObject(base, forKey: key)
    return base
  }
  #if targetEnvironment(simulator)
    // Проверяем окрестность курсора, когда клавиатура закончила составлять знак. Назначаем шрифт
    // только целым цветным значкам, не меняя остальные буквы и ещё набираемый текст.
    static func updateEmoji(in editor: UITextView) {
      guard editor.markedTextRange == nil, let descriptor = emojiDescriptor,
        let font = editor.font ?? editor.typingAttributes[.font] as? UIFont
      else { return }
      let emoji = CTFontCreateWithFontDescriptor(descriptor, font.pointSize, nil) as UIFont
      let value = editor.textStorage.string
      let range = NSRange(location: 0, length: (value as NSString).length)
      // Проверяем соседей курсора. Составной знак может занимать несколько позиций в хранилище строки.
      let cursor = min(editor.selectedRange.location, range.length)
      let changed = NSRange(
        location: max(0, cursor - 1), length: min(range.length, cursor + 1) - max(0, cursor - 1))
      guard changed.length > 0 else { return }
      let nearby = (value as NSString).rangeOfComposedCharacterSequences(for: changed)
      guard let span = Range(nearby, in: value) else { return }
      value.enumerateSubstrings(in: span, options: .byComposedCharacterSequences) {
        substring, bounds, _, _ in
        guard let substring, !substring.unicodeScalars.contains(where: { $0.value == 0xFE0E }),
          substring.unicodeScalars.contains(where: {
            $0.properties.isEmojiPresentation || $0.value == 0xFE0F
          })
        else { return }
        editor.textStorage.addAttribute(.font, value: emoji, range: NSRange(bounds, in: value))
      }
    }
  #endif
  // Готовим строку с нужным шрифтом для измерения. Для имитатора подставляем цветные символы по
  // целым знакам, а при отмене прекращаем лишний обход и возвращаем короткую заготовку.
  static func attributed(
    _ value: String, font: CTFont, size: CGFloat, isCancelled: @escaping () -> Bool = { false }
  ) -> NSAttributedString {
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.black.cgColor
    ]
    if isCancelled() { return NSAttributedString(string: " ", attributes: attributes) }
    let text = NSMutableAttributedString(string: value, attributes: attributes)
    #if targetEnvironment(simulator)
      if let descriptor = emojiDescriptor {
        let emoji = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        value.enumerateSubstrings(
          in: value.startIndex..<value.endIndex, options: .byComposedCharacterSequences
        ) { substring, range, _, stop in
          if isCancelled() {
            stop = true
            return
          }
          guard let substring, !substring.unicodeScalars.contains(where: { $0.value == 0xFE0E }),
            substring.unicodeScalars.contains(where: {
              $0.properties.isEmojiPresentation || $0.value == 0xFE0F
            })
          else { return }
          text.addAttribute(
            NSAttributedString.Key(kCTFontAttributeName as String), value: emoji,
            range: NSRange(range, in: value))
        }
      }
    #endif
    // Отменённая разметка не публикуется. Пустая строка прекращает лишние расчёты текста.
    if isCancelled() { return NSAttributedString(string: " ", attributes: attributes) }
    return text
  }
}
