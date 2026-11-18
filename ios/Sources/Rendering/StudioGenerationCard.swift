import UIKit
import CoreText

struct StudioGenerationCard {
  struct Control {
    let action: StudioGenerationAction
    let frame: CGRect
    let icon: String?
  }

  struct Cell {
    let slot: StudioGeneration.Slot
    let frame: CGRect
  }

  let cells: [Cell]
  let resultFrames: [CGRect]
  var isBatch: Bool { !cells.isEmpty }
  var retryCells: [Cell] { cells.filter { $0.slot.canRetry } }
  var runningCells: [Cell] {
    if isBatch { return cells.filter { $0.slot.status == .running } }
    guard generation.stage == .running, let imageFrame else { return [] }
    return [
      Cell(
        slot: .init(id: "single", status: .running, blobId: nil, progress: generation.progress),
        frame: imageFrame)
    ]
  }
  func sameStaticInk(as old: Self) -> Bool {
    guard imageFrame != nil, imageFrame == old.imageFrame, height == old.height,
      generation.stage == old.generation.stage, cells.count == old.cells.count
    else { return false }
    return zip(cells, old.cells).allSatisfy { a, b in
      a.frame == b.frame && a.slot.id == b.slot.id && a.slot.status == b.slot.status
        && a.slot.moderated == b.slot.moderated
    }
  }
  let generation: StudioGeneration
  let status: String
  let imageFrame: CGRect?
  let statusFrame: CGRect
  let controls: [Control]
  let width: CGFloat
  let height: CGFloat
  let time: String
  private let failureLines: [CTLine]
  private let failureLineHeight: CGFloat

  /// Связывает вложения с ячейками по сохранённым обозначениям, чтобы фотографии занимали свои места.
  init(_ generation: StudioGeneration, message: Message, key: TextLayoutKey, time: String) {
    self.generation = generation
    self.time = time
    let controlHeight = max(48, CGFloat(key.fontSize) * 14 / 18 * 1.45 + 16)
    let slots = generation.slots ?? []
    let batchWidth = max(40, min(300, CGFloat(key.width) - 4))
    let ratio = CGFloat(generation.ratio)
    let layouts = MediaMosaic.layout(
      sizes: slots.map { _ in CGSize(width: ratio, height: 1) }, width: batchWidth,
      scale: CGFloat(key.scale), balancedFour: true)
    let offsetLayouts = layouts.map { $0.offsetBy(dx: 2, dy: 2) }
    if slots.count == 1, let slot = slots.first, !message.attachments.isEmpty || generation.isActive
    {
      let maxHeight: CGFloat = generation.isVideo ? (ratio >= 1 ? 250 : 360) : 380
      let span = min(batchWidth, maxHeight * ratio)
      cells = [Cell(slot: slot, frame: CGRect(x: 2, y: 2, width: span, height: span / ratio))]
    } else {
      cells = zip(slots, offsetLayouts).map { Cell(slot: $0.0, frame: $0.1) }
    }
    let framesByBlob = Dictionary(
      cells.compactMap { cell in cell.slot.blobId.map { ($0, cell.frame) } },
      uniquingKeysWith: { first, _ in first })
    resultFrames = message.attachments.compactMap { framesByBlob[$0.thumbnailKey] }
    if generation.isActive || !cells.isEmpty {
      status = ""
      let frame: CGRect
      if let first = cells.first {
        frame = cells.dropFirst().reduce(first.frame) { $0.union($1.frame) }
      } else {
        let maxHeight: CGFloat = generation.isVideo ? (ratio >= 1 ? 250 : 360) : 380
        let span = max(40, min(batchWidth, maxHeight * ratio))
        frame = CGRect(x: 2, y: 2, width: span, height: span / ratio)
      }
      imageFrame = frame
      width = frame.width + 4
      let top = frame.maxY + 2
      controls = []
      statusFrame = .zero
      height = top
      failureLines = []
      failureLineHeight = 0
    } else {
      status = generation.failureText
      width = min(316, CGFloat(key.width))
      imageFrame = nil
      let fontSize = max(13, CGFloat(key.fontSize) * 15 / 18)
      failureLineHeight = ceil(fontSize * 1.45)
      let source = NSAttributedString(
        string: status,
        attributes: [
          .font: UIFont.systemFont(ofSize: fontSize),
          .foregroundColor: KandinskyPalette.studioMuted
        ])
      let typesetter = CTTypesetterCreateWithAttributedString(source)
      var lines: [CTLine] = [], start = 0
      while start < source.length && lines.count < 6 {
        let available = max(1, Double(width - 22))
        let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, available))
        let line = CTTypesetterCreateLine(
          typesetter, CFRange(location: start, length: min(count, source.length - start)))
        lines.append(line)
        start += count
      }
      failureLines = lines
      let textHeight = CGFloat(lines.count) * failureLineHeight
      statusFrame = CGRect(x: 14, y: 8, width: max(1, width - 22), height: textHeight)
      let top = 8 + textHeight
      controls =
        generation.moderated == true
        ? []
        : [
          Control(
            action: .retry, frame: CGRect(x: 14, y: top, width: 128, height: controlHeight),
            icon: "KandinskyGenerationRefresh")
        ]
      height = top + (controls.isEmpty ? 24 : controlHeight + 20)
    }
  }

  static func progressLabel(_ stage: StudioGeneration.Stage, _ progress: Int?) -> String {
    switch stage {
    case .queued: return "В очереди, 0%"
    case .running: return progress.flatMap { (0..<100).contains($0) ? "\($0)%" : nil } ?? "Создаём"
    case .failed: return "Ошибка"
    case .cancelled: return "Отменено"
    case .succeeded: return "Готово"
    }
  }

  /// Плавное изменение процентов выполняется другим элементом, поэтому здесь не запускается анимация.
  func drawStatic(_ context: CGContext) {
    if let frame = imageFrame {
      if isBatch {
        for cell in cells {
          Self.drawProgress(
            cell.frame, stage: cell.slot.status, canRetry: cell.slot.canRetry, context: context)
        }
      } else {
        Self.drawProgress(frame, stage: generation.stage, canRetry: false, context: context)
      }
      if let retry = controls.first { Self.drawControl(retry, context: context) }
      return
    }
    let fill = UIColor(red: 242.0 / 255, green: 248.0 / 255, blue: 244.0 / 255, alpha: 1)
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 22, y: 0))
    body.addArc(
      tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width, y: height), radius: 16)
    body.addArc(
      tangent1End: CGPoint(x: width, y: height), tangent2End: CGPoint(x: 6, y: height), radius: 16)
    body.addArc(tangent1End: CGPoint(x: 6, y: height), tangent2End: CGPoint(x: 6, y: 0), radius: 5)
    body.addArc(tangent1End: CGPoint(x: 6, y: 0), tangent2End: CGPoint(x: width, y: 0), radius: 16)
    body.closeSubpath()
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 10, y: height - 12))
    tail.addQuadCurve(to: CGPoint(x: 0, y: height - 1), control: CGPoint(x: 5, y: height - 3))
    tail.addQuadCurve(to: CGPoint(x: 13, y: height - 2), control: CGPoint(x: 5, y: height + 1))
    tail.closeSubpath()
    context.setFillColor(fill.cgColor)
    context.addPath(body)
    context.fillPath()
    context.addPath(tail)
    context.fillPath()
    for (index, text) in failureLines.enumerated() {
      Self.drawLine(
        text, x: statusFrame.minX,
        midY: statusFrame.minY + (CGFloat(index) + 0.5) * failureLineHeight, context: context)
    }
    if let retry = controls.first { Self.drawControl(retry, context: context) }
    let stamp = Self.line(
      time, size: 10,
      color: UIColor(red: 86.0 / 255, green: 112.0 / 255, blue: 100.0 / 255, alpha: 1))
    Self.drawLine(
      stamp, x: width - 8 - CGFloat(CTLineGetTypographicBounds(stamp, nil, nil, nil)),
      midY: height - 13, context: context)
  }

  /// У выполняемой и завершённой генерации оставляет только фон, поскольку проценты и готовое медиа
  /// показываются отдельно.
  private static func drawProgress(
    _ frame: CGRect, stage: StudioGeneration.Stage, canRetry: Bool, context: CGContext
  ) {
    fill(frame, corner: 12, color: KandinskyPalette.studioSurface, in: context)
    guard stage != .running, stage != .succeeded else { return }
    let active = stage == .queued
    let radius = min(22, frame.width * 0.24, frame.height * 0.30)
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let diameter = radius * 2
    if active {
      context.saveGState()
      context.setLineWidth(3)
      context.setStrokeColor(
        UIColor(red: 218.0 / 255, green: 236.0 / 255, blue: 226.0 / 255, alpha: 1).cgColor)
      context.strokeEllipse(
        in: CGRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter))
      context.restoreGState()
    }
    if stage == .queued {
      let zero = line("0%", size: 12, color: KandinskyPalette.studioInk, weight: .medium)
      drawLine(
        zero, x: center.x - CGFloat(CTLineGetTypographicBounds(zero, nil, nil, nil)) / 2,
        midY: center.y, context: context)
    }
    let label = line(
      active ? "В очереди" : progressLabel(stage, nil), size: 11, color: KandinskyPalette.studioInk,
      weight: .medium)
    let span = CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil))
    let y =
      active ? min(frame.maxY - 7, center.y + radius + 10) : canRetry ? center.y - 14 : center.y
    drawLine(label, x: center.x - span / 2, midY: y, context: context)
    if canRetry {
      let button = CGRect(x: center.x - 36, y: center.y - 1, width: 72, height: 26)
      fill(
        button, corner: 13,
        color: UIColor(red: 218.0 / 255, green: 236.0 / 255, blue: 226.0 / 255, alpha: 1),
        in: context)
      let title = line("Повторить", size: 11, color: KandinskyPalette.studioInk, weight: .medium)
      drawLine(
        title, x: center.x - CGFloat(CTLineGetTypographicBounds(title, nil, nil, nil)) / 2,
        midY: button.midY, context: context)
    }
  }

  static func drawControl(_ control: Control, context: CGContext) {
    if let icon = control.icon {
      let isRetry = control.action == .retry
      let iconX = isRetry ? control.frame.minX + 12 : control.frame.midX - 10
      let size: CGFloat = isRetry ? 18 : 20
      drawIcon(
        icon, in: CGRect(x: iconX, y: control.frame.midY - size / 2, width: size, height: size),
        context: context)
      if !isRetry { return }
    }
    let label = line(
      control.action.title, size: 14, color: KandinskyPalette.studioInk, weight: .medium)
    let span = CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil))
    let x = control.action == .retry ? control.frame.minX + 38 : control.frame.midX - span / 2
    drawLine(label, x: x, midY: control.frame.midY, context: context)
  }
  private static let icons: [String: CGImage] = {
    let names = ["KandinskyGenerationRefresh"]
    return Dictionary(
      uniqueKeysWithValues: names.compactMap { name in
        UIImage(named: name)?.cgImage.map { (name, $0) }
      })
  }()
  /// Используется при оформлении действий карточки без повторного чтения изображения из ресурсов.
  private static func drawIcon(_ name: String, in rect: CGRect, context: CGContext) {
    guard let icon = icons[name] else { return }
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(icon, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
  }
  private static func fill(_ rect: CGRect, corner: CGFloat, color: UIColor, in context: CGContext) {
    context.setFillColor(color.cgColor)
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.fillPath()
  }
  private static func line(
    _ value: String, size: CGFloat, color: UIColor, weight: UIFont.Weight = .regular
  ) -> CTLine {
    CTLineCreateWithAttributedString(
      NSAttributedString(
        string: value,
        attributes: [
          .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
        ]))
  }
  /// Учитывает высоту букв над строкой и под ней, чтобы подпись выглядела выровненной.
  private static func drawLine(_ line: CTLine, x: CGFloat, midY: CGFloat, context: CGContext) {
    var a: CGFloat = 0, d: CGFloat = 0
    _ = CTLineGetTypographicBounds(line, &a, &d, nil)
    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: x, y: midY + (a - d) / 2)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
  }
}

@MainActor final class StudioProgressLayer: CALayer {
  private let track = CAShapeLayer(), arc = CAShapeLayer(), label = CATextLayer(),
    deliveryLabel = CATextLayer()
  private var value: Int?
  private var bound = false

  /// Настраивает цвета и размеры линий один раз, чтобы следующие обновления меняли только состояние.
  override init() {
    super.init()
    zPosition = 2
    track.fillColor = UIColor.clear.cgColor
    track.strokeColor =
      UIColor(red: 218.0 / 255, green: 236.0 / 255, blue: 226.0 / 255, alpha: 1).cgColor
    arc.fillColor = UIColor.clear.cgColor
    arc.strokeColor = UIColor(red: 0.03, green: 0.62, blue: 0.48, alpha: 1).cgColor
    arc.lineCap = .round
    for layer in [track, arc] {
      layer.lineWidth = 3
      addSublayer(layer)
    }
    for text in [label, deliveryLabel] {
      text.alignmentMode = .center
      text.foregroundColor = KandinskyPalette.studioInk.cgColor
      text.font = UIFont.systemFont(ofSize: 12, weight: .medium).fontName as CFString
      addSublayer(text)
    }
    deliveryLabel.isHidden = true
    deliveryLabel.string = "Загружаем фото"
  }
  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError() }

  func bind(frame: CGRect, progress: Int?, scale: CGFloat, deliveringPhoto: Bool = false) {
    self.frame = frame
    backgroundColor =
      deliveringPhoto ? KandinskyPalette.studioSurface.cgColor : UIColor.clear.cgColor
    cornerRadius = deliveringPhoto ? 12 : 0
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let radius = min(22, frame.width * 0.24, frame.height * 0.30)
    let path = UIBezierPath(
      arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: 3 * .pi / 2,
      clockwise: true
    ).cgPath
    track.frame = bounds
    arc.frame = bounds
    track.path = path
    arc.path = path
    let measured = progress.flatMap { (0..<100).contains($0) ? $0 : nil }
    let motion = !UIAccessibility.isReduceMotionEnabled
    if !bound || measured != value {
      let target = measured.map { CGFloat($0) / 100 } ?? 0.22
      let current = bound ? (arc.presentation()?.strokeEnd ?? arc.strokeEnd) : 0
      arc.strokeEnd = target
      if motion && current != target {
        let change = CABasicAnimation(keyPath: "strokeEnd")
        change.fromValue = current
        change.toValue = target
        change.duration = 0.55
        change.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arc.add(change, forKey: "progress")
      }
      value = measured
      bound = true
    }
    if motion, track.animation(forKey: "pulse") == nil {
      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 0.48
      pulse.toValue = 1
      pulse.duration = 0.8
      pulse.autoreverses = true
      pulse.repeatCount = .infinity
      pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      track.add(pulse, forKey: "pulse")
      arc.add(pulse, forKey: "pulse")
    } else if !motion {
      track.removeAnimation(forKey: "pulse")
      arc.removeAllAnimations()
    }
    label.contentsScale = scale
    label.fontSize = measured == nil ? 11 : 12
    let y = measured == nil ? min(bounds.maxY - 7, center.y + radius + 10) : center.y
    label.frame = CGRect(x: 0, y: y - 7, width: bounds.width, height: 15)
    label.string = StudioGenerationCard.progressLabel(.running, measured)
    deliveryLabel.isHidden = !deliveringPhoto
    if deliveringPhoto {
      deliveryLabel.contentsScale = scale
      deliveryLabel.fontSize = 11
      deliveryLabel.frame = CGRect(
        x: 0, y: min(bounds.maxY - 7, center.y + radius + 10) - 7, width: bounds.width, height: 15)
    }
  }
}
