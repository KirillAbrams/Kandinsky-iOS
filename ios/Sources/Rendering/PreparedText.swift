import UIKit
import CoreText
struct TextLayoutKey: Hashable, Sendable {
  let messageID: MessageID
  let revision: Int
  let width: Int
  let fontSize: Int
  let scale: Int
  let roundDiameter: Int?
  init(
    messageID: MessageID, revision: Int, width: Int, fontSize: Int, scale: Int,
    roundDiameter: Int? = nil
  ) {
    self.messageID = messageID
    self.revision = revision
    self.width = width
    self.fontSize = fontSize
    self.scale = scale
    self.roundDiameter = roundDiameter
  }
}
struct FragmentID: Hashable {
  let messageID: MessageID
  let part: Int
}
struct TextBlock {
  let lines: Range<Int>
  let offsetY: CGFloat
  let height: CGFloat
  let startUTF16: Int
}

enum MessageTimestamp {
  static func string(for milliseconds: Int64, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents(
      [.hour, .minute], from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    let hour = parts.hour ?? 0, minute = parts.minute ?? 0
    let digits: [UInt8] = [
      48 + UInt8(hour / 10), 48 + UInt8(hour % 10), 58, 48 + UInt8(minute / 10),
      48 + UInt8(minute % 10)
    ]
    return String(decoding: digits, as: UTF8.self)
  }
}

enum MessageBubbleBackground {
  static func fill(_ rect: CGRect, radius: CGFloat, color: CGColor, in context: CGContext) {
    context.setFillColor(color)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let transform = context.ctm, device = rect.applying(transform)
    func integral(_ value: CGFloat) -> Bool {
      value.isFinite && abs(value - value.rounded()) < 0.000001
    }
    let aligned =
      transform.b == 0 && transform.c == 0 && transform.a > 0 && transform.d != 0
      && [
        device.minX, device.minY, device.width, device.height, radius * abs(transform.a),
        radius * abs(transform.d)
      ].allSatisfy(integral)
    guard color.alpha == 1, aligned, radius > 0, rect.width >= 2 * radius, rect.height >= 2 * radius
    else {
      context.addPath(path)
      context.fillPath()
      return
    }
    // Keep the original curve and its device-pixel phase. Only the four corners
    // need a coverage mask; a flat interior does not need path antialiasing.
    context.fill(
      CGRect(
        x: rect.minX, y: rect.minY + radius, width: rect.width, height: rect.height - 2 * radius))
    context.fill(
      CGRect(x: rect.minX + radius, y: rect.minY, width: rect.width - 2 * radius, height: radius))
    context.fill(
      CGRect(
        x: rect.minX + radius, y: rect.maxY - radius, width: rect.width - 2 * radius, height: radius
      ))
    for origin in [
      rect.origin, CGPoint(x: rect.maxX - radius, y: rect.minY),
      CGPoint(x: rect.minX, y: rect.maxY - radius),
      CGPoint(x: rect.maxX - radius, y: rect.maxY - radius)
    ] {
      context.saveGState()
      context.clip(to: CGRect(origin: origin, size: CGSize(width: radius, height: radius)))
      context.addPath(path)
      context.fillPath()
      context.restoreGState()
    }
  }
}

/// Bounded, justified rows. Geometry is prepared once with the message, never
/// during scrolling. The picker uses the same engine with two columns.
enum MediaMosaic {
  /// Для четырёх результатов по отдельному признаку оставляет две равные строки, чтобы сохранить сетку
  /// ожидания.
  static func layout(
    sizes: [CGSize], width: CGFloat, spacing: CGFloat = 1, maxColumns: Int = 3, scale: CGFloat = 2,
    balancedFour: Bool = false
  ) -> [CGRect] {
    guard (2...10).contains(sizes.count), width.isFinite, width >= 40 else { return [] }
    let ratios = sizes.map { max(0.667, min(1.7, $0.width / max(1, $0.height))) },
      columns = max(2, min(3, maxColumns))
    let target = width * 4 / 3
    var best: [Int] = [], cost = CGFloat.greatestFiniteMagnitude
    func score(_ rows: [Int]) {
      var index = 0, heights: [CGFloat] = []
      for count in rows {
        let sum = ratios[index..<index + count].reduce(0, +)
        heights.append((width - CGFloat(count - 1) * spacing) / sum)
        index += count
      }
      let total = heights.reduce(0, +) + CGFloat(rows.count - 1) * spacing
      var value = abs(total - target)
      if zip(rows, rows.dropFirst()).contains(where: { $0.0 > $0.1 }) { value *= 1.5 }
      if heights.contains(where: { $0 < width * 0.18 }) { value += width }
      if value < cost {
        best = rows
        cost = value
      }
    }
    func visit(_ remaining: Int, _ rows: [Int]) {
      if remaining == 0 {
        score(rows)
        return
      }
      guard rows.count < max(4, (sizes.count + columns - 1) / columns) else { return }
      for count in 1...min(columns, remaining) { visit(remaining - count, rows + [count]) }
    }
    if balancedFour && sizes.count == 4 {
      best = [2, 2]
    } else if sizes.count == 2 {
      let raw = sizes.map { $0.width / max(1, $0.height) }
      best = raw.allSatisfy { $0 > 1.2 } && abs(raw[0] - raw[1]) < 0.2 ? [1, 1] : [2]
    } else {
      visit(sizes.count, [])
    }
    var result: [CGRect] = [], index = 0, y: CGFloat = 0
    let pixelScale = max(1, scale)
    for count in best {
      let sum = ratios[index..<index + count].reduce(0, +)
      let height = floor((width - CGFloat(count - 1) * spacing) / sum * pixelScale) / pixelScale
      var x: CGFloat = 0
      for column in 0..<count {
        let right =
          column == count - 1
          ? width : floor((x + ratios[index] * height) * pixelScale) / pixelScale
        result.append(CGRect(x: x, y: y, width: max(1, right - x), height: max(1, height)))
        x = right + spacing
        index += 1
      }
      y += height + spacing
    }
    return result
  }
}

enum KandinskyMediaAction: String {
  case save, share, expand

  var title: String {
    switch self {
    case .save: return "Сохранить"
    case .share: return "Поделиться"
    case .expand: return "На весь экран"
    }
  }

  private static let icons: [Self: CGImage] = {
    let color = UIColor(white: 97.0 / 255, alpha: 1)
    return Dictionary(
      uniqueKeysWithValues: [Self.save, .share, .expand].compactMap { action in
        UIImage(named: "Kandinsky" + action.rawValue.capitalized)?.withTintColor(
          color, renderingMode: .alwaysOriginal
        ).cgImage.map { (action, $0) }
      })
  }()

  func draw(in rect: CGRect, context: CGContext) {
    guard let icon = Self.icons[self], context.boundingBoxOfClipPath.intersects(rect) else {
      return
    }
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(icon, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
  }
}

final class PreparedText: @unchecked Sendable {
  private static let sentMediaTimeColor = UIColor(
    red: 112 / 255, green: 177 / 255, blue: 92 / 255, alpha: 1)
  private static let receivedMediaTimeColor = UIColor(
    red: 150 / 255, green: 164 / 255, blue: 174 / 255, alpha: 1)
  private static let promptTimeColor = UIColor(
    red: 86 / 255, green: 112 / 255, blue: 100 / 255, alpha: 1)
  // В одной минуте у соседних входящих сообщений одинаковый рисунок времени.
  private static let incomingTimes: NSCache<NSString, CTLine> = {
    let cache = NSCache<NSString, CTLine>()
    cache.countLimit = 120
    return cache
  }()
  private static func incomingTime(_ text: String) -> CTLine {
    let key = text as NSString
    if let line = incomingTimes.object(forKey: key) { return line }
    let title = NSAttributedString(
      string: text,
      attributes: [
        .font: UIFont.systemFont(ofSize: 12), .foregroundColor: KandinskyPalette.secondary
      ])
    let line = CTLineCreateWithAttributedString(title)
    incomingTimes.setObject(line, forKey: key)
    return line
  }
  private static let emptyMetadataLine = CTLineCreateWithAttributedString(
    NSAttributedString(string: ""))
  let generationCard: StudioGenerationCard?
  let mediaRect: CGRect?
  private let albumFrames: [CGRect]
  let mediaItemRects: [CGRect]
  let mediaOnlyBackground: CGColor?
  let key: TextLayoutKey
  let message: Message
  let width: CGFloat
  let fontPostScriptName: String
  private(set) var blocks: [TextBlock] = []
  private var lines: [CTLine] = []
  private var tops: [CGFloat] = []
  private var ascents: [CGFloat] = []
  private var starts: [Int] = []
  private var lineHeights: [CGFloat] = []
  private let lock = NSLock()
  private var closed = false
  private(set) var closeCount = 0
  let byteCost: Int
  private let textInset: CGFloat
  private let trailingTextInset: CGFloat
  private let isStudioPrompt: Bool
  private var studioPromptBubble: CGPath?
  private let compact: Bool
  private let stamp: CTLine, mediaStamp: CTLine
  private let stampWidth: CGFloat
  private var captionStampInline = false
  private let mediaInfo: CTLine
  private let emojiFontSize: CGFloat?
  var mediaBottomSquare: Bool {
    mediaRect != nil && message.kind != .round && message.kind != .sticker && !text.isEmpty
  }
  private var isStudioResult: Bool {
    message.direction == .incoming && message.attachments.count == 1
      && (message.kind == .photo || message.kind == .video)
  }
  var mediaCornerRadius: CGFloat { isStudioResult ? 12 : message.kind == .sticker ? 0 : 15 }
  let mediaActions: [(action: KandinskyMediaAction, frame: CGRect)]
  private static let actionIconSize: CGFloat = 13.5
  private static func actionIconFrame(_ button: CGRect) -> CGRect {
    CGRect(
      x: button.midX - actionIconSize / 2, y: button.midY - 6 - actionIconSize / 2,
      width: actionIconSize, height: actionIconSize)
  }
  /// Plain text keeps its existing native message owner; only sharp ink needs a bitmap.
  var nativeTextBubbleColor: CGColor? {
    generationCard == nil && !isStudioPrompt && message.kind == .text && emojiFontSize == nil
      && blocks.count == 1
      ? (message.direction == .outgoing ? KandinskyPalette.outgoing : UIColor.white).cgColor : nil
  }
  var height: CGFloat { blocks.last.map { $0.offsetY + $0.height } ?? 44 }
  var text: String {
    message.kind == .text
      ? message.text : (mediaRect == nil ? Self.label(message) : message.caption)
  }
  /// Длинный текст делит на небольшие блоки, чтобы при прокрутке рисовать только нужную часть.
  init(message: Message, key: TextLayoutKey, isCancelled: @escaping () -> Bool = { false }) {
    let prompt = message.kind == .text && message.direction == .outgoing
    let emoji = message.kind == .text && !prompt ? Self.largeEmojiFontSize(message.text) : nil
    isStudioPrompt = prompt
    emojiFontSize = emoji
    self.message = message
    self.key = key
    textInset = prompt ? 14 : emoji == nil ? 10 : 0
    trailingTextInset = prompt ? 20 : 10
    let studioResult =
      message.studioGeneration?.slots?.isEmpty != false && message.direction == .incoming
      && message.attachments.count == 1 && (message.kind == .photo || message.kind == .video)
    let visual =
      !message.attachments.isEmpty
      && [.photo, .video, .round, .gif, .sticker].contains(message.kind)
    let value =
      message.kind == .text ? message.text : (visual ? message.caption : Self.label(message))
    let layoutFont = CGFloat(key.fontSize) * (prompt ? 16.0 / 17.0 : 1)
    let fontSize = min(emoji ?? layoutFont, CGFloat(max(17, key.width - 4)))
    let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
    fontPostScriptName = CTFontCopyPostScriptName(font) as String
    let attributed = PlatformTextFont.attributed(
      value.isEmpty ? " " : value, font: font, size: fontSize, isCancelled: isCancelled)
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let fullLine = CTTypesetterCreateLine(
      typesetter, CFRange(location: 0, length: attributed.length))
    let time = MessageTimestamp.string(for: message.savedAtMs)
    let card = message.studioGeneration.map {
      StudioGenerationCard($0, message: message, key: key, time: time)
    }
    generationCard = card
    if visual && [.video, .round, .gif].contains(message.kind) {
      let info =
        message.kind == .gif
        ? "GIF"
        : String(
          format: message.kind == .round ? "%02lld:%02lld" : "%lld:%02lld",
          max(0, (message.attachments.first?.durationMs ?? 0) / 1000) / 60,
          max(0, (message.attachments.first?.durationMs ?? 0) / 1000) % 60)
      mediaInfo = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: info,
          attributes: [
            .font: UIFont.systemFont(
              ofSize: studioResult ? 11 : 12, weight: studioResult ? .regular : .medium),
            .foregroundColor: UIColor.white
          ]))
    } else {
      mediaInfo = Self.emptyMetadataLine
    }
    let deliveryMark: String
    switch message.delivery {
    case .pending: deliveryMark = " ◷"
    case .failed: deliveryMark = " !"
    case .read: deliveryMark = prompt ? "" : " ✓✓"
    default: deliveryMark = prompt ? "" : " ✓"
    }
    let timestamp = time + (message.direction == .outgoing ? deliveryMark : "")
    let timestampColor: UIColor
    if prompt {
      timestampColor = Self.promptTimeColor
    } else if visual {
      timestampColor =
        message.direction == .outgoing ? Self.sentMediaTimeColor : Self.receivedMediaTimeColor
    } else {
      timestampColor = KandinskyPalette.secondary
    }
    if message.kind == .text && message.direction == .incoming {
      stamp = Self.incomingTime(time)
    } else {
      stamp = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: timestamp,
          attributes: [
            .font: UIFont.systemFont(ofSize: prompt ? 10 : 12), .foregroundColor: timestampColor
          ]))
    }
    if emoji != nil || visual && (message.kind == .sticker || value.isEmpty) {
      mediaStamp = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: time
            + (message.direction == .outgoing
              ? (message.delivery == .pending
                ? " ◷"
                : message.delivery == .failed ? " !" : message.delivery == .read ? " ✓✓" : " ✓")
              : ""),
          attributes: [
            .font: UIFont.systemFont(ofSize: studioResult ? 11 : 12, weight: .regular),
            .foregroundColor: UIColor.white
          ]))
    } else {
      mediaStamp = stamp
    }
    stampWidth = CGFloat(CTLineGetTypographicBounds(stamp, nil, nil, nil))

    let desired = ceil(CGFloat(CTLineGetTypographicBounds(fullLine, nil, nil, nil)))
    compact =
      !prompt && emoji == nil && message.kind == .text && !value.contains("\n")
      && desired + stampWidth + 46 <= CGFloat(key.width)
    let album =
      visual && [.photo, .video].contains(message.kind) && message.attachments.count > 1
      ? MediaMosaic.layout(
        sizes: message.attachments.map {
          CGSize(
            width: max(1, $0.orientation >= 5 ? $0.rawHeight : $0.rawWidth),
            height: max(1, $0.orientation >= 5 ? $0.rawWidth : $0.rawHeight))
        }, width: max(40, min(300, CGFloat(key.width) - 4)), scale: CGFloat(key.scale),
        balancedFour: message.attachments.first?.id.contains("-result-") == true) : []
    albumFrames = album
    let size =
      album.isEmpty
      ? (visual
        ? Self.mediaSize(
          message, bound: CGFloat(key.roundDiameter ?? key.width))
        : nil) : CGSize(width: album.map(\.maxX).max()!, height: album.map(\.maxY).max()!)
    if let card {
      width = card.width
    } else if prompt {
      width = min(
        CGFloat(key.width), max(desired, ceil(stampWidth)) + textInset + trailingTextInset)
    } else {
      width =
        size.map {
          message.kind == .round
            ? min(CGFloat(key.width), $0.width + 36)
            : message.kind == .sticker
              ? max(min(76, CGFloat(key.width)), $0.width + 4) : $0.width + 4
        }
        ?? min(CGFloat(key.width), max(116, desired + (compact ? stampWidth + 46 : textInset + 12)))
    }
    mediaRect =
      (card?.isBatch == true ? card?.imageFrame : nil)
      ?? size.map {
        CGRect(
          x: message.kind == .round ? 0 : 2, y: message.kind == .round ? 4 : 2, width: $0.width,
          height: $0.height)
      }
    mediaItemRects =
      (card?.isBatch == true ? card?.resultFrames : nil) ?? mediaRect.map { rect in
        album.isEmpty ? [rect] : album.map { $0.offsetBy(dx: rect.minX, dy: rect.minY) }
      } ?? []
    if studioResult, value.isEmpty, let mediaRect {
      let actions: [KandinskyMediaAction] =
        message.kind == .video ? [.save, .share, .expand] : [.save, .share]
      let buttonWidth = min(48, mediaRect.width / CGFloat(actions.count))
      let buttonHeight = max(48, CGFloat(key.fontSize) * 14 / 18 * 1.45 + 16)
      mediaActions = actions.enumerated().map { index, action in
        (
          action,
          CGRect(
            x: mediaRect.minX + CGFloat(index) * buttonWidth, y: mediaRect.maxY + 2,
            width: buttonWidth, height: buttonHeight)
        )
      }
    } else {
      mediaActions = []
    }
    let availableTextWidth = max(20, width - textInset - trailingTextInset)
    var start = 0, y: CGFloat = (mediaRect?.maxY ?? 0) + (prompt ? 9 : emoji == nil ? 8 : 16)
    while card == nil && start < attributed.length && !isCancelled() {
      var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(availableTextWidth))
      if count <= 0 {
        count = max(
          1, CTTypesetterSuggestClusterBreak(typesetter, start, Double(availableTextWidth)))
      }
      let line = CTTypesetterCreateLine(
        typesetter, CFRange(location: start, length: min(count, attributed.length - start)))
      var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
      _ = CTLineGetTypographicBounds(line, &a, &d, &l)
      let h = ceil(max(fontSize * (prompt ? 1.4 : 1.2), a + d + l))
      lines.append(line)
      tops.append(y - (compact ? 1.2 : 0))
      ascents.append(a)
      starts.append(start)
      lineHeights.append(h)
      y += h
      start += count
    }
    if visual, message.kind != .round, !value.isEmpty, let last = lines.last {
      let runs = CTLineGetGlyphRuns(last) as! [CTRun],
        rtl = runs.first.map { CTRunGetStatus($0).contains(.rightToLeft) } ?? false
      captionStampInline =
        !rtl
        && CGFloat(CTLineGetTypographicBounds(last, nil, nil, nil)) + stampWidth + 8 <= width
          - textInset - 11
    }
    var first = 0, offset: CGFloat = 0
    while first < lines.count {
      var end = first
      while end < lines.count && end - first < 16
        && (end == first || tops[end] + lineHeights[end] - offset <= 400)
      { end += 1 }
      let bottom: CGFloat
      if end < lines.count {
        bottom = tops[end]
      } else if prompt {
        bottom = y + 21
      } else if let action = mediaActions.last {
        bottom = action.frame.maxY
      } else if visual && value.isEmpty {
        bottom = mediaRect!.maxY + (message.kind == .sticker ? 26 : 2)
      } else if visual && captionStampInline {
        bottom = y + 6
      } else if compact {
        bottom = max(36, y + 5)
      } else {
        bottom = max(44, y + 18)
      }
      blocks.append(
        TextBlock(
          lines: first..<end, offsetY: offset, height: bottom - offset, startUTF16: starts[first]))
      first = end
      offset = bottom
    }
    if let card {
      blocks = [TextBlock(lines: 0..<0, offsetY: 0, height: card.height, startUTF16: 0)]
    }
    byteCost =
      value.utf16.count * 2 + lines.count * 256 + blocks.count * 64 + 512
      + message.attachments.reduce(0) {
        $0 + ($1.tinyPreview?.utf8.count ?? 0) * 2 + ($1.waveform?.count ?? 0)
      }
    if card == nil && visual && value.isEmpty {
      if message.kind == .round || message.kind == .sticker || !mediaActions.isEmpty {
        mediaOnlyBackground = UIColor.clear.cgColor
      } else {
        mediaOnlyBackground =
          (message.direction == .outgoing
          ? UIColor(red: 239 / 255, green: 1, blue: 222 / 255, alpha: 1) : .white).cgColor
      }
    } else {
      mediaOnlyBackground = nil
    }
    if prompt, let last = blocks.last {
      studioPromptBubble = Self.promptBubble(width: width, height: last.offsetY + last.height)
    }
  }
  private static func promptBubble(width: CGFloat, height: CGFloat) -> CGPath {
    let bodyRight = width - 6
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 16, y: 0))
    path.addArc(
      tangent1End: CGPoint(x: bodyRight, y: 0), tangent2End: CGPoint(x: bodyRight, y: height),
      radius: 16)
    path.addArc(
      tangent1End: CGPoint(x: bodyRight, y: height), tangent2End: CGPoint(x: 0, y: height),
      radius: 5)
    path.addArc(tangent1End: CGPoint(x: 0, y: height), tangent2End: CGPoint(x: 0, y: 0), radius: 16)
    path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: bodyRight, y: 0), radius: 16)
    path.closeSubpath()
    path.move(to: CGPoint(x: width - 10, y: height - 12))
    path.addQuadCurve(
      to: CGPoint(x: width, y: height - 1), control: CGPoint(x: width - 5, y: height - 3))
    path.addQuadCurve(
      to: CGPoint(x: width - 13, y: height - 2), control: CGPoint(x: width - 5, y: height + 1))
    path.closeSubpath()
    return path
  }
  /// Возвращает только геометрию, чтобы подготовка текста не зависела от загрузки самого файла.
  private static func mediaSize(_ message: Message, bound: CGFloat) -> CGSize? {
    guard let a = message.attachments.first else { return nil }
    if message.kind == .round {
      let d = max(40, min(212, bound))
      return CGSize(width: d, height: d)
    }
    let rw = CGFloat(max(1, a.orientation >= 5 ? a.rawHeight : a.rawWidth)),
      rh = CGFloat(max(1, a.orientation >= 5 ? a.rawWidth : a.rawHeight))
    if message.kind == .sticker {
      let limit = max(1, min(180, bound - 4)), scale = min(limit / rw, limit / rh)
      return CGSize(width: max(1, rw * scale), height: max(1, rh * scale))
    }
    let maxW = max(40, min(300, bound - 4)),
      maxH: CGFloat = message.kind == .video ? (rw >= rh ? 250 : 360) : 380
    let scale = min(maxW / rw, maxH / rh)
    if message.direction == .incoming, message.attachments.count == 1,
      message.kind == .photo || message.kind == .video
    {
      return CGSize(width: rw * scale, height: rh * scale)
    }
    return CGSize(
      width: min(maxW, max(min(170, maxW), rw * scale)), height: min(maxH, max(74, rh * scale)))
  }
  private static func label(_ m: Message) -> String {

    let title: [MessageKind: String] = [
      .photo: "▧ Фотография", .video: "▶ Видео", .voice: "◉ Голосовое сообщение",
      .round: "◉ Видеокружочек", .gif: "GIF", .sticker: "Стикер"
    ]
    return (title[m.kind] ?? "") + (m.caption.isEmpty ? "" : "\n" + m.caption)
  }
  private static func largeEmojiFontSize(_ text: String) -> CGFloat? {
    guard !text.isEmpty else { return nil }
    var count = 0, maxLine = 0, line = 0, lines = 1
    for character in text {
      if character == "\n" {
        maxLine = max(maxLine, line)
        line = 0
        lines += 1
        continue
      }
      if character == " " { continue }
      let scalars = character.unicodeScalars
      guard let first = scalars.first, first.properties.isEmoji,
        first.properties.isEmojiPresentation
          || scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 })
          || first.value > 0x238C
      else { return nil }
      count += 1
      line += 1
    }
    guard count > 0 else { return nil }
    let length = max(max(maxLine, line), lines),
      multipliers: [CGFloat] = [1, 0.84, 0.69, 0.53, 0.46, 0.38, 0.32, 0.27, 0.24]
    return floor(94 * (length <= multipliers.count ? multipliers[length - 1] : 0.21))
  }
  func lineAnchor(y: CGFloat) -> (Int, CGFloat)? {
    guard let i = tops.indices.first(where: { tops[$0] + lineHeights[$0] > y }) ?? tops.indices.last
    else { return nil }
    return (starts[i], tops[i] - y)
  }
  func y(forUTF16 value: Int) -> CGFloat? {
    guard !starts.isEmpty else { return nil }
    var lo = 0, hi = starts.count
    while lo < hi {
      let m = (lo + hi) / 2
      if starts[m] <= value { lo = m + 1 } else { hi = m }
    }
    return tops[max(0, lo - 1)]
  }
  struct AccessibleLine {
    let start: Int
    let text: String
    let frame: CGRect
  }
  func accessibleLines(from lower: CGFloat, to upper: CGFloat, limit: Int) -> [AccessibleLine] {
    guard limit > 0 else { return [] }
    if let card = generationCard {
      let frame = card.statusFrame
      return frame.maxY > lower && frame.minY < upper
        ? [AccessibleLine(start: 0, text: card.status, frame: frame)] : []
    }
    guard !tops.isEmpty else { return [] }
    var lo = 0, hi = tops.count
    while lo < hi {
      let m = (lo + hi) / 2
      if tops[m] + lineHeights[m] <= lower { lo = m + 1 } else { hi = m }
    }
    let source = text as NSString
    var result: [AccessibleLine] = []
    var i = lo
    while i < lines.count && tops[i] < upper && result.count < limit {
      let range = CTLineGetStringRange(lines[i])
      let end = min(source.length, range.location + range.length)
      let value =
        range.location < end
        ? source.substring(with: NSRange(location: range.location, length: end - range.location))
          .trimmingCharacters(in: .newlines) : ""
      if !value.isEmpty {
        result.append(
          AccessibleLine(
            start: range.location, text: value,
            frame: CGRect(
              x: textInset, y: tops[i], width: max(1, width - textInset - trailingTextInset),
              height: lineHeights[i])))
      }
      i += 1
    }
    return result
  }
  /// На время рисования удерживает защиту данных, чтобы закрытие объекта не освободило используемые строки.
  func draw(part: Int, in context: CGContext, drawsBackground: Bool = true) {
    lock.lock()
    defer { lock.unlock() }
    guard blocks.indices.contains(part), !closed else { return }
    if let card = generationCard {
      card.drawStatic(context)
      return
    }
    let b = blocks[part]
    let fill =
      mediaOnlyBackground
      ?? (message.direction == .outgoing ? KandinskyPalette.outgoing : .white).cgColor
    context.setFillColor(fill)
    if drawsBackground && message.kind != .round && message.kind != .sticker && emojiFontSize == nil
    {
      let rect = CGRect(x: 0, y: -b.offsetY, width: width, height: height)
      if let studioPromptBubble {
        context.saveGState()
        context.translateBy(x: 0, y: -b.offsetY)
        context.addPath(studioPromptBubble)
        context.fillPath()
        context.restoreGState()
      } else if mediaRect == nil {
        MessageBubbleBackground.fill(rect, radius: 14, color: fill, in: context)
      } else {
        context.addPath(
          CGPath(roundedRect: rect, cornerWidth: 17, cornerHeight: 17, transform: nil))
        context.fillPath()
      }
    }

    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: 0, y: b.height)
    context.scaleBy(x: 1, y: -1)
    for i in b.lines {
      let runs = CTLineGetGlyphRuns(lines[i]) as! [CTRun]
      let rtl = runs.first.map { CTRunGetStatus($0).contains(.rightToLeft) } ?? false
      let x =
        textInset
        + CGFloat(
          CTLineGetPenOffsetForFlush(
            lines[i], rtl ? 1 : 0, Double(width - textInset - trailingTextInset)))
      context.textPosition = CGPoint(x: x, y: b.height - (tops[i] - b.offsetY) - ascents[i])
      CTLineDraw(lines[i], context)
    }
    if part == blocks.count - 1 {
      if emojiFontSize == nil && !(mediaRect != nil && text.isEmpty) {
        let baseline =
          isStudioPrompt
          ? 11
          : captionStampInline
            ? b.height - (tops.last! - b.offsetY) - ascents.last!
            : compact ? b.height - tops[0] - ascents[0] - 3 : 7
        context.textPosition = CGPoint(
          x: width - stampWidth - (isStudioPrompt ? trailingTextInset : 11), y: baseline)
        CTLineDraw(stamp, context)
      }
    }
    context.restoreGState()
    if emojiFontSize != nil, part == blocks.count - 1 {
      let w = CGFloat(CTLineGetTypographicBounds(mediaStamp, nil, nil, nil)),
        box = CGRect(x: max(0, width - w - 10), y: b.height - 18, width: w + 10, height: 18)
      context.setFillColor(UIColor.black.withAlphaComponent(0.28).cgColor)
      context.addPath(CGPath(roundedRect: box, cornerWidth: 9, cornerHeight: 9, transform: nil))
      context.fillPath()
      context.saveGState()
      context.textMatrix = .identity
      context.translateBy(x: 0, y: b.height)
      context.scaleBy(x: 1, y: -1)
      context.textPosition = CGPoint(x: box.minX + 5, y: 4)
      CTLineDraw(mediaStamp, context)
      context.restoreGState()
    }
  }
  var hasMediaStamp: Bool {
    guard generationCard == nil, mediaRect != nil else { return false }
    return [.video, .gif, .round, .sticker].contains(message.kind) || text.isEmpty
  }
  private func studioMediaBadges(in rect: CGRect) -> [(CTLine, CGRect)] {
    let badgeHeight: CGFloat = 17.2
    var badges: [(CTLine, CGRect)] = []
    if message.kind == .video {
      let width = CGFloat(CTLineGetTypographicBounds(mediaInfo, nil, nil, nil)) + 10
      badges.append(
        (mediaInfo, CGRect(x: rect.minX + 6, y: rect.minY + 6, width: width, height: badgeHeight)))
    }
    if text.isEmpty {
      let width = CGFloat(CTLineGetTypographicBounds(mediaStamp, nil, nil, nil)) + 10
      badges.append(
        (
          mediaStamp,
          CGRect(
            x: rect.maxX - 6 - width, y: rect.maxY - 6 - badgeHeight, width: width,
            height: badgeHeight)
        ))
    }
    return badges
  }
  var mediaStampRegions: [CGRect] {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, hasMediaStamp, let rect = mediaRect else { return [] }
    if isStudioResult { return studioMediaBadges(in: rect).map(\.1) }
    var regions: [CGRect] = []
    func pill(_ line: CTLine, x: CGFloat, y: CGFloat) {
      regions.append(
        CGRect(
          x: x, y: y, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 10,
          height: 18))
    }
    if message.kind == .video || message.kind == .gif {
      pill(mediaInfo, x: rect.minX + 6, y: rect.minY + 6)
    }
    let w = CGFloat(CTLineGetTypographicBounds(mediaStamp, nil, nil, nil))
    if message.kind == .sticker {
      pill(mediaStamp, x: max(0, width - w - 10), y: rect.maxY + 4)
      return regions
    }
    if message.kind == .round {
      pill(mediaInfo, x: rect.minX + 3, y: rect.maxY - 22)
      regions.append(CGRect(x: rect.midX - 12, y: rect.minY + 2, width: 24, height: 24))
    }
    if text.isEmpty {
      pill(
        mediaStamp,
        x: message.kind == .round
          ? min(width - w - 12, rect.maxX + 28 - w - 10) : rect.maxX - w - 16,
        y: message.kind == .round ? rect.maxY - 22 : rect.maxY - 24)
    }
    return regions
  }
  var mediaOverlayRegions: [CGRect] {
    let stamps = mediaStampRegions
    guard let first = mediaActions.first, let last = mediaActions.last else { return stamps }
    return stamps + [Self.actionIconFrame(first.frame).union(Self.actionIconFrame(last.frame))]
  }
  func drawMediaStamp(in context: CGContext, manual: Bool = false) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, let rect = mediaRect else { return }
    if isStudioResult {
      context.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
      for (line, box) in studioMediaBadges(in: rect) {
        context.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: box.minX + 5, y: height - box.maxY + 4)
        CTLineDraw(line, context)
        context.restoreGState()
      }
      if !manual {
        for button in mediaActions {
          button.action.draw(in: Self.actionIconFrame(button.frame), context: context)
        }
      }
      return
    }
    func pill(_ line: CTLine, x: CGFloat, y: CGFloat) {
      let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)),
        box = CGRect(x: x, y: y, width: w + 10, height: 18)
      context.setFillColor(UIColor.black.withAlphaComponent(0.36).cgColor)
      context.addPath(CGPath(roundedRect: box, cornerWidth: 9, cornerHeight: 9, transform: nil))
      context.fillPath()
      context.saveGState()
      context.textMatrix = .identity
      context.translateBy(x: 0, y: height)
      context.scaleBy(x: 1, y: -1)
      context.textPosition = CGPoint(x: box.minX + 5, y: height - box.maxY + 4)
      CTLineDraw(line, context)
      context.restoreGState()
    }
    if message.kind == .video || message.kind == .gif {
      pill(mediaInfo, x: rect.minX + 6, y: rect.minY + 6)
    }
    if message.kind == .sticker {
      let w = CGFloat(CTLineGetTypographicBounds(mediaStamp, nil, nil, nil))
      pill(mediaStamp, x: max(0, width - w - 10), y: rect.maxY + 4)
      return
    }
    if message.kind == .round && !manual {
      pill(mediaInfo, x: rect.minX + 3, y: rect.maxY - 22)
      let center = CGPoint(x: rect.midX, y: rect.minY + 14)
      context.setFillColor(UIColor.black.withAlphaComponent(0.28).cgColor)
      context.fillEllipse(in: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24))
      context.setFillColor(UIColor.white.cgColor)
      context.move(to: CGPoint(x: center.x - 7, y: center.y - 3))
      context.addLine(to: CGPoint(x: center.x - 3, y: center.y - 3))
      context.addLine(to: CGPoint(x: center.x + 1, y: center.y - 7))
      context.addLine(to: CGPoint(x: center.x + 1, y: center.y + 7))
      context.addLine(to: CGPoint(x: center.x - 3, y: center.y + 3))
      context.addLine(to: CGPoint(x: center.x - 7, y: center.y + 3))
      context.closePath()
      context.fillPath()
      context.setLineWidth(1.7)
      context.setLineCap(.round)
      context.setStrokeColor(UIColor.white.cgColor)
      context.move(to: CGPoint(x: center.x + 4, y: center.y - 3))
      context.addLine(to: CGPoint(x: center.x + 9, y: center.y + 3))
      context.move(to: CGPoint(x: center.x + 9, y: center.y - 3))
      context.addLine(to: CGPoint(x: center.x + 4, y: center.y + 3))
      context.strokePath()
    }
    if text.isEmpty {
      let w = CGFloat(CTLineGetTypographicBounds(mediaStamp, nil, nil, nil))
      pill(
        mediaStamp,
        x: message.kind == .round
          ? min(width - w - 12, rect.maxX + 28 - w - 10) : rect.maxX - w - 16,
        y: message.kind == .round ? rect.maxY - 22 : rect.maxY - 24)
    }
  }
  func close() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closed = true
    closeCount += 1
    lines.removeAll()
    blocks.removeAll()
    tops.removeAll()
    starts.removeAll()
    ascents.removeAll()
    lineHeights.removeAll()
  }
}
