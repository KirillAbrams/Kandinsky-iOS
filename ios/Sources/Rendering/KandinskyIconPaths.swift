// Здесь хранятся контуры кнопок переписки на айфоне. Контур строится один раз. Кнопка применяет
// цвет, размер и область нажатия при каждом показе.

import UIKit
enum IconID: CaseIterable, Hashable {
  case menu, compose, chevronDown, tune, plus, send, stop
}
enum KandinskyIconPaths {
  private static let paths: [IconID: CGPath] = Dictionary(
    uniqueKeysWithValues: IconID.allCases.map { icon in
      let p = CGMutablePath()
      // Начинаем линию первой парой координат и ведём через остальные пары. Без пары точек
      // видимого отрезка не получится.
      func line(_ values: [CGFloat]) {
        guard values.count >= 4 else { return }
        p.move(to: CGPoint(x: values[0], y: values[1]))
        for i in stride(from: 2, to: values.count, by: 2) {
          p.addLine(to: CGPoint(x: values[i], y: values[i + 1]))
        }
      }
      switch icon {
      case .menu:
        for y in [CGFloat(6), 11, 16] { p.addRect(CGRect(x: 3, y: y, width: 18, height: 2)) }
      case .compose:
        line([14, 3, 5, 3])
        p.addQuadCurve(to: CGPoint(x: 3, y: 5), control: CGPoint(x: 3, y: 3))
        p.addLine(to: CGPoint(x: 3, y: 21))
        p.addQuadCurve(to: CGPoint(x: 5, y: 23), control: CGPoint(x: 3, y: 23))
        p.addLine(to: CGPoint(x: 21, y: 23))
        p.addQuadCurve(to: CGPoint(x: 23, y: 21), control: CGPoint(x: 23, y: 23))
        p.addLine(to: CGPoint(x: 23, y: 13))
        line([11, 13, 20, 4])
        p.addQuadCurve(to: CGPoint(x: 22, y: 4), control: CGPoint(x: 21, y: 3))
        p.addLine(to: CGPoint(x: 24, y: 6))
        p.addQuadCurve(to: CGPoint(x: 24, y: 8), control: CGPoint(x: 25, y: 7))
        p.addLine(to: CGPoint(x: 15, y: 17))
        p.addLine(to: CGPoint(x: 10, y: 18))
        p.closeSubpath()
      case .chevronDown: line([6, 9, 12, 15, 18, 9])
      case .tune:
        line([3, 6, 8, 6])
        line([12, 6, 21, 6])
        line([8, 4, 8, 8])
        line([3, 12, 15, 12])
        line([19, 12, 21, 12])
        line([15, 10, 15, 14])
        line([3, 18, 8, 18])
        line([12, 18, 21, 18])
        line([8, 16, 8, 20])
      case .plus:
        line([
          19, 13, 13, 13, 13, 19, 11, 19, 11, 13, 5, 13, 5, 11, 11, 11, 11, 5, 13, 5, 13, 11, 19,
          11
        ])
        p.closeSubpath()
      case .send:
        line([4, 12, 5.41, 13.41, 11, 7.83, 11, 20, 13, 20, 13, 7.83, 18.59, 13.41, 20, 12, 12, 4])
        p.closeSubpath()
      case .stop:
        p.addRoundedRect(
          in: CGRect(x: 5, y: 5, width: 14, height: 14), cornerWidth: 2, cornerHeight: 2)
      }
      return (icon, p.copy()!)
    })
  // Переводим контур в заданный прямоугольник и выбираем заливку или обводку по виду значка.
  // После рисунка возвращаем параметры холста, чтобы следующая кнопка не унаследовала его
  // масштаб.
  static func draw(_ icon: IconID, in rect: CGRect, color: UIColor, width: CGFloat = 1.8) {
    guard let context = UIGraphicsGetCurrentContext(), let path = paths[icon] else { return }

    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.minY)
    let referenceSide: CGFloat = icon == .compose ? 26 : 24
    context.scaleBy(x: rect.width / referenceSide, y: rect.height / referenceSide)
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(path)
    if [.menu, .plus, .send, .stop].contains(icon) {
      context.setFillColor(color.cgColor)
      context.fillPath()
    } else {
      context.strokePath()
    }
    context.restoreGState()
  }
}
@MainActor final class KandinskyIconButton: UIControl {
  // После смены значка обновляем рисунок кнопки. Например, место отправки занимает остановка.
  var icon: IconID { didSet { if icon != oldValue { setNeedsDisplay() } } }
  var iconColor: UIColor = .darkGray
  var iconHidden = false
  var iconSide: CGFloat?
  var solid = false
  var solidColor = KandinskyPalette.blue
  var circle = true
  var hitExtension: CGFloat = 0
  // Связываем кнопку со значком и подписью доступности. События касания просят новый кадр, чтобы
  // нажатие сразу меняло вид.
  init(icon: IconID, id: String, label: String) {
    self.icon = icon
    super.init(frame: .zero)
    backgroundColor = .clear
    accessibilityIdentifier = id
    accessibilityLabel = label
    accessibilityTraits = .button
    isAccessibilityElement = true
    addTarget(
      self, action: #selector(feedback),
      for: [.touchDown, .touchUpInside, .touchCancel, .touchDragExit])
  }
  // Принимаем значок и подпись при создании из кода. У сохранённой разметки нужных параметров
  // нет.
  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }
  // Просим перерисовать кнопку при нажатии и отпускании. Так выделенное состояние пропадает после
  // завершения касания.
  @objc private func feedback() { setNeedsDisplay() }
  override var accessibilityFrame: CGRect {
    // Если область касания расширена, переводим её в экранные координаты и для озвучивания. В
    // обычном случае достаточно системной рамки.
    get {
      guard hitExtension > 0 else { return super.accessibilityFrame }
      let target = bounds.insetBy(dx: -hitExtension, dy: -hitExtension)
      return UIAccessibility.convertToScreenCoordinates(target, in: self)
    }
    // Передаём явно заданную рамку системе. При обычной кнопке она остаётся источником координат
    // доступности.
    set { super.accessibilityFrame = newValue }
  }

  // Проверяем расширенный прямоугольник для маленьких кнопок. Значок может остаться компактным, а
  // нажать рядом с ним всё ещё можно.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard hitExtension > 0 else { return super.point(inside: point, with: event) }
    return bounds.insetBy(dx: -hitExtension, dy: -hitExtension).contains(point)
  }

  // Рисуем круг или обводку и помещаем значок по центру. При нажатии меняем прозрачность заливки,
  // а у скрытого значка оставляем область пустой.
  override func draw(_ rect: CGRect) {
    guard !iconHidden else { return }
    let side = min(bounds.width, bounds.height) - 7
    let circleRect = CGRect(
      x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    if solid {
      (isHighlighted ? solidColor.withAlphaComponent(0.7) : solidColor).setFill()
      UIBezierPath(ovalIn: circleRect).fill()
    } else if circle {
      KandinskyPalette.line.setStroke()
      let p = UIBezierPath(ovalIn: circleRect)
      p.lineWidth = 0.6
      p.stroke()
    }
    let sideIcon: CGFloat = iconSide ?? (solid ? 24 : 23)
    KandinskyIconPaths.draw(
      icon,
      in: CGRect(
        x: (bounds.width - sideIcon) / 2, y: (bounds.height - sideIcon) / 2, width: sideIcon,
        height: sideIcon), color: solid ? .white : iconColor, width: solid ? 2.5 : 1.6)
  }
}
