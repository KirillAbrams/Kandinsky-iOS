// Сверяет координаты изображения при повороте, отражении и заполнении рамки. Неверные размеры и
// ориентации должны получать отказ.

import CoreGraphics
import XCTest

@testable import Kandinsky

extension PhotoPresentation {
  // Применяет преобразование к выбранной точке. Проверка может сравнить углы и внутренние
  // координаты с независимыми значениями.
  fileprivate func point(x: Double, y: Double) -> CGPoint {
    CGPoint(x: x, y: y).applying(affineTransform)
  }
}

final class PhotoPresentationTests: XCTestCase {
  // Проверяет попадание большого исходника в высокую рамку до и после поворота. Края выходят за
  // рамку симметрично, а высота заполнена точно.
  func testOriginal2048FillsViewportWithCenteredCrop() throws {
    let p = try XCTUnwrap(
      PhotoPresentation.filling(
        rawWidth: 2048, rawHeight: 1536, orientation: 1, width: 390, height: 844))
    XCTAssertEqual(p.point(x: 0, y: 0).x, -367.6667, accuracy: 0.001)
    XCTAssertEqual(p.point(x: 0, y: 0).y, 0, accuracy: 0.001)
    XCTAssertEqual(p.point(x: 2048, y: 1536).x, 757.6667, accuracy: 0.001)
    XCTAssertEqual(p.point(x: 2048, y: 1536).y, 844, accuracy: 0.001)
    let rotated = try XCTUnwrap(
      PhotoPresentation.filling(
        rawWidth: 2048, rawHeight: 1536, orientation: 6, width: 390, height: 844))
    XCTAssertEqual(rotated.point(x: 0, y: 0).x, 511.5, accuracy: 0.001)
    XCTAssertEqual(rotated.point(x: 0, y: 0).y, 0, accuracy: 0.001)
    XCTAssertEqual(rotated.point(x: 2048, y: 1536).x, -121.5, accuracy: 0.001)
    XCTAssertEqual(rotated.point(x: 2048, y: 1536).y, 844, accuracy: 0.001)
  }
  // Сверяет четыре точки для каждой из восьми ориентаций, проверяет кадрирование и неверные
  // числа. Повтор одинакового запроса должен дать одинаковые координаты.
  func testSourceOrientationAndValidationContract() {
    let expected: [[[Double]]] = [
      [[16, 8], [48, 8], [16, 24], [48, 24]], [[48, 8], [16, 8], [48, 24], [16, 24]],
      [[48, 24], [16, 24], [48, 8], [16, 8]], [[16, 24], [48, 24], [16, 8], [48, 8]],
      [[8, 16], [8, 48], [24, 16], [24, 48]], [[24, 16], [24, 48], [8, 16], [8, 48]],
      [[24, 48], [24, 16], [8, 48], [8, 16]], [[8, 48], [8, 16], [24, 48], [24, 16]],
    ]
    let points: [(Double, Double)] = [(2, 1), (6, 1), (2, 3), (6, 3)]
    for o in 1...8 {
      guard
        let p = PhotoPresentation.filling(
          rawWidth: 8, rawHeight: 4, orientation: o, width: o >= 5 ? 32 : 64,
          height: o >= 5 ? 64 : 32)
      else {
        XCTFail("Valid orientation rejected")
        return
      }
      for i in 0..<4 {
        let v = p.point(x: points[i].0, y: points[i].1)
        XCTAssertEqual(v.x, expected[o - 1][i][0], accuracy: 1e-8, "Orientation \(o)")
        XCTAssertEqual(v.y, expected[o - 1][i][1], accuracy: 1e-8, "Orientation \(o)")
      }
    }
    let fill = PhotoPresentation.filling(
      rawWidth: 8, rawHeight: 4, orientation: 1, width: 80, height: 80)
    XCTAssertEqual(fill?.a, 20)
    XCTAssertEqual(fill?.d, 20)
    XCTAssertEqual(fill?.tx, -40)
    XCTAssertEqual(fill?.ty, 0)
    for v in [
      (0, 4, 1, 80.0, 80.0), (8, 0, 1, 80, 80), (2049, 4, 1, 80, 80), (8, 4, 0, 80, 80),
      (8, 4, 9, 80, 80), (8, 4, 1, 0, 80), (8, 4, 1, 80, -1), (8, 4, 1, Double.nan, 80),
      (8, 4, 1, 80, Double.infinity), (8, 4, 1, 8193, 80),
    ] {
      XCTAssertNil(
        PhotoPresentation.filling(
          rawWidth: v.0, rawHeight: v.1, orientation: v.2, width: v.3, height: v.4))
    }
    for _ in 0..<1000 {
      XCTAssertEqual(
        PhotoPresentation.filling(
          rawWidth: 8, rawHeight: 4, orientation: 1, width: 80, height: 80),
        fill)
    }
  }
  // Проверяет положение угла прямоугольного снимка после поворота в квадрате. Так можно поймать
  // ошибку переноса даже при верном масштабе.
  func testRotationSixFillsSquare() throws {
    let p = try XCTUnwrap(
      PhotoPresentation.filling(
        rawWidth: 100, rawHeight: 50, orientation: 6, width: 200, height: 200))
    XCTAssertEqual(p.point(x: 0, y: 0).x, 200)
    XCTAssertEqual(p.point(x: 0, y: 0).y, -100)
  }
}
