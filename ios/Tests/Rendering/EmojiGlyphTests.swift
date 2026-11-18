// Проверяем, что составной семейный знак остаётся цветным после подготовки и рисования сообщения
// в чате.

import XCTest
import UIKit
@testable import Kandinsky
@MainActor final class EmojiGlyphTests: XCTestCase {
  // Рисуем готовый блок и считаем пиксели с заметной разницей цветовых каналов. Размер текста
  // сам по себе не показал бы, что вместо цветного знака вышел пустой квадрат.
  func testZWJFamilyDrawsActualColoredGlyphPixels() {
    let message = Message(
      id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .incoming,
      savedAtMs: 1, kind: .text, text: "👨‍👩‍👧‍👦", caption: "", replyToID: nil, revision: 1,
      attachments: [])
    let p = PreparedText(
      message: message,
      key: TextLayoutKey(messageID: 1, revision: 1, width: 280, fontSize: 30, scale: 2))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let result = UIGraphicsImageRenderer(
      size: CGSize(width: p.width, height: p.height), format: format
    ).image { ctx in p.draw(part: 0, in: ctx.cgContext) }
    let image = result.cgImage!, w = image.width, h = image.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    rgba.withUnsafeMutableBytes { bytes in
      let c = CGContext(
        data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var colored = 0
    for n in stride(from: 0, to: rgba.count, by: 4) {
      let a = Int(rgba[n]), b = Int(rgba[n + 1]), c = Int(rgba[n + 2])
      if max(a, b, c) - min(a, b, c) > 35 { colored += 1 }
    }
    XCTAssertGreaterThan(
      colored, 25,
      "ZWJ data preservation alone is insufficient: the native glyph must render in color")
  }
}
