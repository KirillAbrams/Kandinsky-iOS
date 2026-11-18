import UIKit

@MainActor enum KandinskyWallpaper {
  private static let pattern = UIImage(named: "KandinskyEvolution")

  static func renderHeader(bounds: CGRect) {
    UIColor.white.setFill()
    UIRectFill(bounds)
  }

  static func render(bounds: CGRect, scale: CGFloat) {
    guard let context = UIGraphicsGetCurrentContext(), bounds.width > 0, bounds.height > 0 else {
      return
    }
    context.saveGState()
    context.clip(to: bounds)
    renderHeader(bounds: bounds)
    if let pattern {
      let ratio = max(bounds.width / pattern.size.width, bounds.height / pattern.size.height)
      let size = CGSize(width: pattern.size.width * ratio, height: pattern.size.height * ratio)
      let rect = CGRect(
        x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
        width: size.width, height: size.height)
      pattern.draw(in: rect, blendMode: .normal, alpha: 1.0 / 12.0)
    }
    context.restoreGState()
  }
}
