import CoreText
import UIKit

enum KandinskyPalette {
  static let blue = UIColor(red: 0, green: 0.51, blue: 1, alpha: 1)
  static let secondary = UIColor(white: 0.44, alpha: 1)
  static let line = UIColor(white: 0.72, alpha: 0.55)
  static let outgoing = UIColor(red: 217.0 / 255, green: 241.0 / 255, blue: 228.0 / 255, alpha: 1)
  static let studioInk = UIColor(red: 22.0 / 255, green: 24.0 / 255, blue: 22.0 / 255, alpha: 1)
  static let studioMuted = UIColor(
    red: 116.0 / 255, green: 121.0 / 255, blue: 116.0 / 255, alpha: 1)
  static let studioSheet = UIColor(
    red: 239.0 / 255, green: 245.0 / 255, blue: 240.0 / 255, alpha: 1)
  static let studioSheetHandle = UIColor(
    red: 64.0 / 255, green: 73.0 / 255, blue: 68.0 / 255, alpha: 1)
  static let studioSurface = UIColor(
    red: 244.0 / 255, green: 244.0 / 255, blue: 242.0 / 255, alpha: 1)
  static let studioBorder = UIColor(
    red: 229.0 / 255, green: 232.0 / 255, blue: 226.0 / 255, alpha: 1)

  enum StudioBrandPlacement {
    case toolbar, drawer, welcome
  }

  private static func studioTitle(fontSize: CGFloat, spacing: CGFloat) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
      .kern: spacing,
      NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): studioInk
        .cgColor,
    ]
    return CTLineCreateWithAttributedString(
      NSAttributedString(string: "Kandinsky", attributes: attributes))
  }

  private static let studioToolbarTitle = studioTitle(fontSize: 29, spacing: -0.7 * 29 / 20)
  private static let studioDrawerTitle = studioTitle(fontSize: 20, spacing: -0.7)
  private static let studioWelcomeTitle = studioTitle(fontSize: 25, spacing: -0.7)

  static func studioBrand(x: CGFloat, top: CGFloat, placement: StudioBrandPlacement = .toolbar) {
    // В исходном оформлении три места знака используют разные унаследованные параметры строки
    let (size, width, baseline, verticalScale, title): (CGFloat, CGFloat, CGFloat, CGFloat, CTLine)
    switch placement {
    case .toolbar:
      (size, width, baseline, verticalScale, title) = (
        24, 86.15, 19.31, 20 / 29, studioToolbarTitle
      )
    case .drawer:
      (size, width, baseline, verticalScale, title) = (24, 95.49, 19.11, 1, studioDrawerTitle)
    case .welcome:
      (size, width, baseline, verticalScale, title) = (32, 120.93, 25.01, 1, studioWelcomeTitle)
    }
    let left = placement == .drawer ? x : x - (size + 9 + width) / 2
    let scale = size / 24
    let mint = UIColor(red: 56.0 / 255, green: 227.0 / 255, blue: 178.0 / 255, alpha: 1)
    let darkMint = UIColor(red: 25.0 / 255, green: 207.0 / 255, blue: 161.0 / 255, alpha: 1)
    let polygons: [(UIColor, [CGPoint])] = [
      (mint, [.init(x: 0, y: 6), .init(x: 6, y: 0), .init(x: 6, y: 12), .init(x: 0, y: 18)]),
      (darkMint, [.init(x: 0, y: 18), .init(x: 6, y: 12), .init(x: 6, y: 18), .init(x: 0, y: 24)]),
      (mint, [.init(x: 6, y: 12), .init(x: 18, y: 0), .init(x: 24, y: 0), .init(x: 12, y: 12)]),
      (mint, [.init(x: 6, y: 12), .init(x: 12, y: 12), .init(x: 24, y: 24), .init(x: 18, y: 24)]),
    ]
    for (color, points) in polygons {
      let path = UIBezierPath()
      for (index, point) in points.enumerated() {
        let position = CGPoint(x: left + point.x * scale, y: top + point.y * scale)
        if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
      }
      path.close()
      color.setFill()
      path.fill()
    }
    guard let context = UIGraphicsGetCurrentContext() else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: left + size + 9, y: top + baseline)
    context.scaleBy(
      x: width / CGFloat(CTLineGetTypographicBounds(title, nil, nil, nil)), y: -verticalScale)
    context.textMatrix = .identity
    context.textPosition = .zero
    CTLineDraw(title, context)
  }
  static let empty = UIColor(red: 0.87, green: 0.96, blue: 0.89, alpha: 0.97)
  static func text(
    _ text: String, in rect: CGRect, size: CGFloat, color: UIColor = .black,
    weight: UIFont.Weight = .regular, alignment: NSTextAlignment = .left
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    (text as NSString).draw(
      in: rect,
      withAttributes: [
        .font: PlatformTextFont.uiFont(size: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph,
      ])
  }
}
