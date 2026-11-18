import UIKit

@MainActor final class MediaProgressControl: UIControl {
  private let ring = CAShapeLayer(), cross = CAShapeLayer()
  var foregroundColor: UIColor = .white {
    didSet {
      ring.strokeColor = foregroundColor.cgColor
      cross.strokeColor = foregroundColor.cgColor
    }
  }
  private var retry = false
  override init(frame: CGRect) {
    super.init(frame: frame)
    isHidden = true
    isAccessibilityElement = true
    accessibilityIdentifier = "media.cancel"
    accessibilityLabel = "Отменить загрузку"
    backgroundColor = UIColor.black.withAlphaComponent(0.42)
    ring.fillColor = UIColor.clear.cgColor
    ring.strokeColor = UIColor.white.cgColor
    ring.lineWidth = 2.5
    ring.lineCap = .round
    cross.fillColor = UIColor.clear.cgColor
    cross.strokeColor = UIColor.white.cgColor
    cross.lineWidth = 2.5
    cross.lineCap = .round
    layer.addSublayer(ring)
    layer.addSublayer(cross)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.width / 2
    ring.frame = bounds
    ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).cgPath
    cross.frame = bounds
    let p = UIBezierPath()
    p.move(to: CGPoint(x: 18, y: 18))
    p.addLine(to: CGPoint(x: 30, y: 30))
    p.move(to: CGPoint(x: 30, y: 18))
    p.addLine(to: CGPoint(x: 18, y: 30))
    if retry {
      let arrow = UIBezierPath(
        arcCenter: CGPoint(x: 24, y: 24), radius: 8, startAngle: -CGFloat.pi / 2,
        endAngle: CGFloat.pi * 1.2, clockwise: true)
      arrow.move(to: CGPoint(x: 21, y: 12))
      arrow.addLine(to: CGPoint(x: 27, y: 16))
      arrow.addLine(to: CGPoint(x: 21, y: 19))
      cross.path = arrow.cgPath
    } else {
      cross.path = p.cgPath
    }
  }
  func update(progress: Double?, visible: Bool, retry: Bool = false) {
    self.retry = retry
    accessibilityIdentifier = retry ? "media.retry" : "media.cancel"
    accessibilityLabel = retry ? "Повторить загрузку" : "Отменить загрузку"
    setNeedsLayout()
    isHidden = !visible
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.strokeEnd = CGFloat(progress ?? 0.72)
    CATransaction.commit()
    if visible && progress == nil && !retry {
      if ring.animation(forKey: "loading") == nil {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.toValue = Double.pi * 2
        a.duration = 1
        a.repeatCount = .infinity
        ring.add(a, forKey: "loading")
      }
    } else {
      ring.removeAnimation(forKey: "loading")
    }
    accessibilityValue = progress.map { String(Int($0 * 100)) + "%" } ?? "Загрузка"
  }
}
