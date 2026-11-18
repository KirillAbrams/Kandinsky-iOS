// Полупрозрачная панель на айфоне использует системное стекло, если оно доступно, и размытие на
// более старой системе. Тень и слабый блеск лежат отдельно, поэтому не перехватывают касания
// кнопок.

import UIKit
@MainActor final class NativeGlassInk: UIView {
  // Назначение нового рисунка просит обновить слой, даже если размеры панели прежние.
  var paint: ((CGRect) -> Void)? { didSet { setNeedsDisplay() } }
  // Создаём прозрачную область дополнительного рисунка. Она не принимает касания, чтобы подложка
  // не мешала действиям пользователя.
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }
  // Слой получает действие рисования после создания из кода. Восстановление без этого действия не
  // используется.
  required init?(coder: NSCoder) { fatalError() }
  // Передаём действию текущие границы всего слоя. Дополнительный рисунок поэтому совпадает с
  // подложкой и после смены размера.
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
  // При новом скруглении заново согласуем контур подложки и тени.
  var radius: CGFloat = 29 { didSet { setNeedsLayout() } }
  // Собираем размытие, блеск и тень отдельными слоями. Вся панель пропускает касания к соседним
  // кнопкам, которые отвечают за ввод.
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
  // Запрещаем создание из файла разметки. В обычном создании сразу собираются нужные слои и
  // правила обработки касаний.
  required init?(coder: NSCoder) { fatalError() }
  // Подгоняем размытие и блеск под текущий размер и скругление. Тень получает тот же контур,
  // чтобы края совпали.
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
