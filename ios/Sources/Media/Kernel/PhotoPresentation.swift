// Готовит правила показа фото с учётом поворота, отражения и размера области. Само изображение не
// копируется.

import CoreGraphics

/// Поворачиваем и отражаем изображение при выводе. Отдельная копия пикселей для этого не нужна.
struct PhotoPresentation: Equatable, Sendable {
  let a, b, c, d, tx, ty: Double

  var affineTransform: CGAffineTransform {
    CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
  }

  // Проверяет размеры и указание ориентации, затем вычисляет масштаб для заполнения и смещение к
  // середине. Без этих поправок снимок мог бы оказаться перевёрнутым или оставить пустые края.
  static func filling(
    rawWidth: Int, rawHeight: Int, orientation: Int, width: Double, height: Double
  ) -> Self? {
    guard (1...2048).contains(rawWidth), (1...2048).contains(rawHeight),
      (1...8).contains(orientation),
      width.isFinite, height.isFinite, width > 0, height > 0, width <= 8192, height <= 8192
    else { return nil }
    let w = Double(rawWidth), h = Double(rawHeight), sw = orientation >= 5 ? h : w,
      sh = orientation >= 5 ? w : h
    let scale = max(width / sw, height / sh)
    let x = (width - sw * scale) / 2, y = (height - sh * scale) / 2
    let a, b, c, d, tx, ty: Double
    switch orientation {
    case 1: (a, b, c, d, tx, ty) = (1, 0, 0, 1, 0, 0)
    case 2: (a, b, c, d, tx, ty) = (-1, 0, 0, 1, w, 0)
    case 3: (a, b, c, d, tx, ty) = (-1, 0, 0, -1, w, h)
    case 4: (a, b, c, d, tx, ty) = (1, 0, 0, -1, 0, h)
    case 5: (a, b, c, d, tx, ty) = (0, 1, 1, 0, 0, 0)
    case 6: (a, b, c, d, tx, ty) = (0, 1, -1, 0, h, 0)
    case 7: (a, b, c, d, tx, ty) = (0, -1, -1, 0, h, w)
    default: (a, b, c, d, tx, ty) = (0, -1, 1, 0, 0, w)
    }
    return Self(
      a: a * scale, b: b * scale, c: c * scale, d: d * scale, tx: x + tx * scale, ty: y + ty * scale
    )
  }
}
