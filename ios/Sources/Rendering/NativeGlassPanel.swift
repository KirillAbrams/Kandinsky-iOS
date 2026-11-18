import UIKit
@MainActor final class NativeGlassInk: UIView {
  var paint: ((CGRect) -> Void)? { didSet { setNeedsDisplay() } }
  /// Отключает обработку касаний, чтобы эта область не мешала кнопкам и другим элементам.
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }
  required init?(coder: NSCoder) { fatalError() }
  /// Использует актуальные размеры элемента, чтобы дополнительный слой совпадал с подложкой.
  override func draw(_ rect: CGRect) { paint?(bounds) }
}
@MainActor final class NativeGlassPanel: UIView {
  private let blur: UIVisualEffectView = {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.tintColor = UIColor.white.withAlphaComponent(0.05)
      return UIVisualEffectView(effect: effect)
    }
    return UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
  }()
  let ink = NativeGlassInk(frame: .zero)
  var radius: CGFloat = 29 { didSet { setNeedsLayout() } }
  /// Отключает собственную обработку касаний, чтобы подложка не перехватывала действия пользователя.
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
    addSubview(blur)
    blur.contentView.addSubview(ink)
    layer.shadowColor = UIColor(red: 0.12, green: 0.30, blue: 0.17, alpha: 1).cgColor
    layer.shadowOpacity = 0.06
    layer.shadowRadius = 6
    layer.shadowOffset = CGSize(width: 0, height: 2)
    ink.paint = { bounds in
      guard let c = UIGraphicsGetCurrentContext() else { return }
      let colors =
        [
          UIColor.white.withAlphaComponent(0.06).cgColor,
          UIColor.white.withAlphaComponent(0.0).cgColor
        ] as CFArray
      if let g = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
      {
        c.drawLinearGradient(
          g, start: .zero, end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
      }
    }
  }
  /// Контейнер создаётся кодом, чтобы сразу собрать необходимые слои оформления.
  required init?(coder: NSCoder) { fatalError() }
  /// Обновляет контур тени по тем же размерам, чтобы она совпадала с формой подложки.
  override func layoutSubviews() {
    super.layoutSubviews()
    blur.frame = bounds
    blur.layer.cornerRadius = radius
    blur.layer.cornerCurve = .continuous
    blur.clipsToBounds = true
    ink.frame = blur.bounds
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
  }
}
