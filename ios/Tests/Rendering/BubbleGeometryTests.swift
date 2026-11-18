// Проверяем размеры сообщений с текстом, фото и видео. Отступы и кнопки сравниваем с точными
// координатами, чтобы смена расчёта не сдвинула элементы чата.

import XCTest
@testable import Kandinsky
final class BubbleGeometryTests: XCTestCase {
  // Сверяем высоту короткой строки, положение фото и места кнопок под ним. У видео должна
  // добавляться кнопка раскрытия, а под одиночным фото не должно появляться непрозрачной
  // подложки.
  func testReferenceShortTextAndPhotoActionFooter() {
    let text = Message(
      id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .incoming,
      savedAtMs: 1, kind: .text, text: "Ndjfjd", caption: "", replyToID: nil, revision: 1,
      attachments: [])
    let t = PreparedText(
      message: text,
      key: TextLayoutKey(messageID: 1, revision: 1, width: 280, fontSize: 17, scale: 2))
    XCTAssertLessThanOrEqual(t.height, 36)
    XCTAssertEqual(t.accessibleLines(from: 0, to: 1000, limit: 10).count, 1)
    let a = Attachment(
      id: "ref", relativePath: "seed/photo-000.jpg", mime: "image/jpeg", byteSize: 10,
      rawWidth: 413, rawHeight: 275, orientation: 1, durationMs: nil, thumbnailKey: "")
    let photo = Message(
      id: 2, chatID: 2, order: OrderKey(sortKey: 2, messageID: 2), direction: .incoming,
      savedAtMs: 1, kind: .photo, text: "", caption: "", replyToID: nil, revision: 1,
      attachments: [a])
    let p = PreparedText(
      message: photo,
      key: TextLayoutKey(messageID: 2, revision: 1, width: 280, fontSize: 17, scale: 2))
    XCTAssertEqual(p.height, p.mediaRect!.maxY + 50, accuracy: 0.01)
    XCTAssertEqual(p.mediaRect!.minX, 2)
    XCTAssertEqual(p.mediaCornerRadius, 12)
    XCTAssertEqual(p.mediaStampRegions.count, 1)
    XCTAssertEqual(p.mediaStampRegions.first!.maxX, p.mediaRect!.maxX - 6, accuracy: 0.01)
    XCTAssertEqual(p.mediaStampRegions.first!.maxY, p.mediaRect!.maxY - 6, accuracy: 0.01)
    XCTAssertEqual(p.mediaActions.map(\.action), [.save, .share])
    let first = p.mediaActions[0].frame
    XCTAssertEqual(first, CGRect(x: 2, y: p.mediaRect!.maxY + 2, width: 48, height: 48))
    let video = Message(
      id: 4, chatID: 2, order: OrderKey(sortKey: 4, messageID: 4), direction: .incoming,
      savedAtMs: 1, kind: .video, text: "", caption: "", replyToID: nil, revision: 1,
      attachments: [a])
    let v = PreparedText(
      message: video,
      key: TextLayoutKey(messageID: 4, revision: 1, width: 280, fontSize: 17, scale: 2))
    XCTAssertEqual(v.mediaActions.map(\.action), [.save, .share, .expand])
    let iconRegion = p.mediaOverlayRegions.last!.integral
    let width = Int(iconRegion.width), height = Int(iconRegion.height)
    let bitmap = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.translateBy(x: 0, y: CGFloat(height))
    bitmap.scaleBy(x: 1, y: -1)
    bitmap.translateBy(x: -iconRegion.minX, y: -iconRegion.minY)
    p.drawMediaStamp(in: bitmap)
    let pixels = bitmap.data!.assumingMemoryBound(to: UInt8.self)
    XCTAssertTrue((0..<(width * height)).contains { pixels[4 * $0 + 3] > 100 })
    XCTAssertEqual(p.mediaOnlyBackground?.alpha, 0)
  }
  // Проверяем отступ текста, общую высоту и форму хвостика исходящего запроса. Время остаётся на
  // отдельном месте, а хвостик появляется только внизу.
  func testKandinskyPromptKeepsSeparateTimestampAndTail() throws {
    let prompt = Message(
      id: 3, chatID: 2, order: OrderKey(sortKey: 3, messageID: 3), direction: .outgoing,
      savedAtMs: 1, kind: .text, text: "Медиа 191", caption: "", replyToID: nil, revision: 1,
      attachments: [])
    let prepared = PreparedText(
      message: prompt,
      key: TextLayoutKey(messageID: 3, revision: 1, width: 280, fontSize: 17, scale: 2))
    let line = try XCTUnwrap(prepared.accessibleLines(from: 0, to: 1000, limit: 1).first)
    XCTAssertEqual(line.frame.minX, 14)
    XCTAssertEqual(line.frame.minY, 9)
    XCTAssertEqual(prepared.height, 53, accuracy: 0.01)

    let scale: CGFloat = 2
    let width = Int(ceil(prepared.width * scale)), height = Int(ceil(prepared.height * scale))
    let bitmap = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.translateBy(x: 0, y: CGFloat(height))
    bitmap.scaleBy(x: scale, y: -scale)
    prepared.draw(part: 0, in: bitmap)
    let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
    let tailX = width - 4
    // Читаем прозрачность одного пикселя на выбранной горизонтальной позиции. Так отличаем нижний
    // хвостик от случайного окрашивания той же позиции посередине.
    func alpha(_ y: Int) -> UInt8 { pixels[y * bitmap.bytesPerRow + tailX * 4 + 3] }
    XCTAssertEqual(alpha(height / 2), 0)
    XCTAssertGreaterThan((height - 8..<height).map(alpha).max() ?? 0, 100)
  }
}
