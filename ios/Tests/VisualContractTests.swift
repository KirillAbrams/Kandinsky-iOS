// Проверяем сохранённые свойства внешнего вида, набор кнопок и состав выпускаемой сборки.

import UIKit
import XCTest

@testable import Kandinsky

@MainActor final class VisualContractTests: XCTestCase {
  // Открываем старое звуковое вложение и сверяем подпись, время и нарисованные пиксели. Данные
  // старой записи сохраняются, но на экране нет прежней дорожки и кнопки воспроизведения.
  func testStoredAudioKeepsCaptionWithoutVoiceControls() throws {
    let attachment = Attachment(
      id: "old-audio", relativePath: "old/audio.m4a", mime: "audio/mp4", byteSize: 147046,
      rawWidth: 0, rawHeight: 0, orientation: 1, durationMs: 7000, thumbnailKey: "",
      waveform: Array(repeating: 255, count: 64))
    let row = Message(
      id: 901, chatID: 2, order: OrderKey(sortKey: 1, messageID: 901), direction: .incoming,
      savedAtMs: 0, kind: .voice, text: "", caption: "Сохранённая подпись", replyToID: nil,
      revision: 1, attachments: [attachment])
    let prepared = PreparedText(
      message: row,
      key: TextLayoutKey(messageID: 901, revision: 1, width: 300, fontSize: 17, scale: 1))
    defer { prepared.close() }
    XCTAssertEqual(prepared.text, "◉ Голосовое сообщение\nСохранённая подпись")
    let first = try XCTUnwrap(
      prepared.accessibleLines(from: 0, to: prepared.height, limit: 20).first)
    XCTAssertEqual(first.frame.minX, 10, accuracy: 0.1)
    XCTAssertFalse(prepared.text.contains("00:07"))
    let width = Int(ceil(prepared.width))
    let height = Int(ceil(prepared.height))
    let bitmap = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue))
    bitmap.translateBy(x: 0, y: CGFloat(height))
    bitmap.scaleBy(x: 1, y: -1)
    prepared.draw(part: 0, in: bitmap)
    let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
    let blue = (0..<(width * height)).filter {
      pixels[4 * $0] < 60 && pixels[4 * $0 + 1] > 90 && pixels[4 * $0 + 1] < 180
        && pixels[4 * $0 + 2] > 220 && pixels[4 * $0 + 3] > 200
    }
    XCTAssertTrue(blue.isEmpty, "Stored audio has no playback button or waveform")
    XCTAssertEqual(row.attachments.first?.waveform, Array(repeating: 255, count: 64))
  }

  // Ищем проверочные вложения отдельно в приложении и в наборе тестов. Фото должно читаться
  // только из тестового набора, чтобы выпуск не содержал его копию.
  func testFixtureFilesBelongOnlyToTestBundle() throws {
    XCTAssertNil(Bundle.main.url(forResource: "fixtures", withExtension: nil))
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let data = try Data(contentsOf: fixture.appendingPathComponent("media/photo-000.jpg"))
    XCTAssertFalse(data.isEmpty)
  }

  // Загружаем по именам значки генерации, меню и вложений. При случайном исключении нужного файла
  // проверка назовёт отсутствующий значок.
  func testGenerationArtworkRemainsInApplication() {
    for name in [
      "KandinskyAttachmentCamera", "KandinskyAttachmentPhoto", "KandinskyDrawerAdd",
      "KandinskyDrawerArchive", "KandinskyDrawerBack", "KandinskyDrawerLogout",
      "HeroiconsPaperClip", "KandinskyDrawerMore", "KandinskyDrawerSearch", "KandinskyEvolution",
      "KandinskyExpand", "KandinskyGenerationRefresh", "KandinskyModelCheck",
      "KandinskyModelVideo", "KandinskyRecentVideo", "KandinskySave", "KandinskyShare",
      "KandinskyUploadClose",
    ] {
      XCTAssertNotNil(UIImage(named: name, in: Bundle.main, compatibleWith: nil), name)
    }
  }

  // Открываем упакованный текст лицензии значков и сверяем вид лицензии и имя правообладателя.
  // Это помогает заметить случайное исключение обязательного файла.
  func testHeroiconsLicenseIsIncludedInApplication() throws {
    let file = try XCTUnwrap(
      Bundle.main.url(forResource: "Heroicons-LICENSE", withExtension: "txt"))
    let text = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(text.contains("MIT License"))
    XCTAssertTrue(text.contains("Tailwind Labs"))
  }

  // Сверяем метки, размеры и видимость нужных кнопок. У старых действий голосового сообщения,
  // круглого видео и анимации не должно остаться доступных кнопок.
  func testComposerContainsOnlyGenerationControls() throws {
    let view = ConversationChrome(chatID: 2, onBack: {})
    let expected = ["composer.plus", "composer.model", "composer.settings", "composer.send"]
    for width in [CGFloat(320), 394] {
      view.frame = CGRect(x: 0, y: 0, width: width, height: 852)
      view.setNeedsLayout()
      view.layoutIfNeeded()
      for id in expected {
        let control = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == id }, id)
        XCTAssertGreaterThan(control.bounds.width, 0, id)
        XCTAssertGreaterThan(control.bounds.height, 0, id)
        XCTAssertGreaterThanOrEqual(control.frame.minX, 0, id)
        XCTAssertLessThanOrEqual(control.frame.maxX, width, id)
        XCTAssertFalse(control.accessibilityLabel?.isEmpty ?? true, id)
      }
      let ids = Set(view.subviews.compactMap(\.accessibilityIdentifier))
      XCTAssertTrue(ids.isDisjoint(with: ["composer.voice", "composer.round", "composer.gif"]))
    }
  }
}
