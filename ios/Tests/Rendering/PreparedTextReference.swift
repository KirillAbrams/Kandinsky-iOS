// Храним отдельный образец подготовки текста для сравнения размеров, картинки, места чтения и
// времени работы. Образец измеряет строку отдельно или тем же измерителем, который разбивает её
// на части.

import CoreText
import UIKit

@testable import Kandinsky

final class PreparedTextReference: @unchecked Sendable {
  enum Measurement {
    case separateLine
    case sharedTypesetter
  }

  let mediaRect: CGRect?
  let mediaItemRects: [CGRect]
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
  let byteCost: Int
  private let textInset: CGFloat
  private let compact: Bool
  private let stamp: CTLine, mediaStamp: CTLine
  private let stampWidth: CGFloat
  private var captionStampInline = false
  private let mediaInfo: CTLine
  private let emojiFontSize: CGFloat?
  // Считаем высоту по нижнему краю последней части. Пустой образец сохраняет минимальную высоту
  // сообщения.
  var height: CGFloat { blocks.last.map { $0.offsetY + $0.height } ?? 44 }
  // Выбираем текст сообщения, подпись вложения или запасную метку. Этот же выбор нужен для
  // сравнения доступных строк.
  var text: String {
    message.kind == .text
      ? message.text : (mediaRect == nil ? Self.label(message) : message.caption)
  }
  // Готовим ширину, строки, части, подписи и время по прежним правилам оформления. Отдельный
  // образец нужен, чтобы проверка новой разметки не повторяла её возможную ошибку.
  init(message: Message, key: TextLayoutKey, measurement: Measurement = .separateLine) {
    let emoji = message.kind == .text ? Self.largeEmojiFontSize(message.text) : nil
    emojiFontSize = emoji
    self.message = message
    self.key = key
    self.textInset = emoji == nil ? 10 : 0
    let visual =
      !message.attachments.isEmpty
      && [.photo, .video, .round, .gif, .sticker].contains(message.kind)
    let value =
      message.kind == .text ? message.text : (visual ? message.caption : Self.label(message))
    let fontSize = min(emoji ?? CGFloat(key.fontSize), CGFloat(max(17, key.width - 4)))
    let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
    fontPostScriptName = CTFontCopyPostScriptName(font) as String
    let attributed = PlatformTextFont.attributed(
      value.isEmpty ? " " : value, font: font, size: fontSize)
    let referenceTypesetter: CTTypesetter?
    let fullLine: CTLine
    switch measurement {
    case .separateLine:
      referenceTypesetter = nil
      fullLine = CTLineCreateWithAttributedString(attributed)
    case .sharedTypesetter:
      let typesetter = CTTypesetterCreateWithAttributedString(attributed)
      referenceTypesetter = typesetter
      fullLine = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: attributed.length))
    }
    let time = MessageTimestamp.string(for: message.savedAtMs)
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
          .font: UIFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: UIColor.white,
        ]))
    let mediaColor =
      message.direction == .outgoing
      ? UIColor(red: 112 / 255, green: 177 / 255, blue: 92 / 255, alpha: 1)
      : UIColor(red: 150 / 255, green: 164 / 255, blue: 174 / 255, alpha: 1)
    stamp = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: time
          + (message.direction == .outgoing
            ? (message.delivery == .pending
              ? " ◷"
              : message.delivery == .failed ? " !" : message.delivery == .read ? " ✓✓" : " ✓")
            : ""),
        attributes: [
          .font: UIFont.systemFont(ofSize: 12),
          .foregroundColor: visual ? mediaColor : KandinskyPalette.secondary,
        ]))
    mediaStamp = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: time
          + (message.direction == .outgoing
            ? (message.delivery == .pending
              ? " ◷"
              : message.delivery == .failed ? " !" : message.delivery == .read ? " ✓✓" : " ✓")
            : ""),
        attributes: [
          .font: UIFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: UIColor.white,
        ]))
    stampWidth = CGFloat(CTLineGetTypographicBounds(stamp, nil, nil, nil))
    let desired = ceil(CGFloat(CTLineGetTypographicBounds(fullLine, nil, nil, nil)))
    compact =
      emoji == nil && message.kind == .text && !value.contains("\n")
      && desired + stampWidth + 46 <= CGFloat(key.width)
    let album =
      visual && [.photo, .video].contains(message.kind) && message.attachments.count > 1
      ? MediaMosaic.layout(
        sizes: message.attachments.map {
          CGSize(
            width: max(1, $0.orientation >= 5 ? $0.rawHeight : $0.rawWidth),
            height: max(1, $0.orientation >= 5 ? $0.rawWidth : $0.rawHeight))
        }, width: max(40, min(300, CGFloat(key.width) - 4)), scale: CGFloat(key.scale)) : []
    let size =
      album.isEmpty
      ? (visual
        ? Self.mediaSize(message, bound: CGFloat(key.roundDiameter ?? key.width))
        : nil) : CGSize(width: album.map(\.maxX).max()!, height: album.map(\.maxY).max()!)
    width =
      size.map {
        message.kind == .round
          ? min(CGFloat(key.width), $0.width + 36)
          : message.kind == .sticker ? max(min(76, CGFloat(key.width)), $0.width + 4) : $0.width + 4
      }
      ?? min(CGFloat(key.width), max(116, desired + (compact ? stampWidth + 46 : textInset + 12)))
    mediaRect = size.map {
      CGRect(
        x: message.kind == .round ? 0 : 2, y: message.kind == .round ? 4 : 2, width: $0.width,
        height: $0.height)
    }
    mediaItemRects =
      mediaRect.map { rect in
        album.isEmpty ? [rect] : album.map { $0.offsetBy(dx: rect.minX, dy: rect.minY) }
      } ?? []
    let typesetter = referenceTypesetter ?? CTTypesetterCreateWithAttributedString(attributed)
    var start = 0
    var y: CGFloat = (mediaRect?.maxY ?? 0) + (emoji == nil ? 8 : 16)
    while start < attributed.length {
      var count = CTTypesetterSuggestLineBreak(
        typesetter, start, Double(max(20, width - textInset - 10)))
      if count <= 0 {
        count = max(
          1,
          CTTypesetterSuggestClusterBreak(
            typesetter, start, Double(max(20, width - textInset - 10))))
      }
      let line = CTTypesetterCreateLine(
        typesetter, CFRange(location: start, length: min(count, attributed.length - start)))
      var a: CGFloat = 0
      var d: CGFloat = 0
      var l: CGFloat = 0
      _ = CTLineGetTypographicBounds(line, &a, &d, &l)
      let h = ceil(max(fontSize * 1.2, a + d + l))
      lines.append(line)
      tops.append(y - (compact ? 1.2 : 0))
      ascents.append(a)
      starts.append(start)
      lineHeights.append(h)
      y += h
      start += count
    }
    if visual, message.kind != .round, !value.isEmpty, let last = lines.last {
      let runs = CTLineGetGlyphRuns(last) as! [CTRun]
      let rtl = runs.first.map { CTRunGetStatus($0).contains(.rightToLeft) } ?? false
      captionStampInline =
        !rtl
        && CGFloat(CTLineGetTypographicBounds(last, nil, nil, nil)) + stampWidth + 8 <= width
          - textInset - 11
    }
    var first = 0
    var offset: CGFloat = 0
    while first < lines.count {
      var end = first
      while end < lines.count && end - first < 16
        && (end == first || tops[end] + lineHeights[end] - offset <= 400)
      { end += 1 }
      let bottom =
        end == lines.count
        ? (visual && value.isEmpty
          ? mediaRect!.maxY + (message.kind == .sticker ? 26 : 2)
          : visual && captionStampInline
            ? y + 6 : compact ? max(36, y + 5) : max(44, y + 18))
        : tops[end]
      blocks.append(
        TextBlock(
          lines: first..<end, offsetY: offset, height: bottom - offset, startUTF16: starts[first]))
      first = end
      offset = bottom
    }
    byteCost =
      value.utf16.count * 2 + lines.count * 256 + blocks.count * 64 + 512
      + message.attachments.reduce(0) {
        $0 + ($1.tinyPreview?.utf8.count ?? 0) * 2 + ($1.waveform?.count ?? 0)
      }
  }
  // Считаем размер первого вложения по его пропорциям и доступной ширине. Для круглого видео
  // берём отдельный диаметр, а для остальных учитываем разворот и предельную высоту.
  private static func mediaSize(_ message: Message, bound: CGFloat) -> CGSize? {
    guard let a = message.attachments.first else { return nil }
    if message.kind == .round {
      let d = max(40, min(212, bound))
      return CGSize(width: d, height: d)
    }
    let rw = CGFloat(max(1, a.orientation >= 5 ? a.rawHeight : a.rawWidth))
    let rh = CGFloat(max(1, a.orientation >= 5 ? a.rawWidth : a.rawHeight))
    if message.kind == .sticker {
      let limit = max(1, min(180, bound - 4))
      let scale = min(limit / rw, limit / rh)
      return CGSize(width: max(1, rw * scale), height: max(1, rh * scale))
    }
    let maxW = max(40, min(300, bound - 4))
    let maxH: CGFloat = message.kind == .video ? (rw >= rh ? 250 : 360) : 380
    let scale = min(maxW / rw, maxH / rh)
    return CGSize(
      width: min(maxW, max(min(170, maxW), rw * scale)), height: min(maxH, max(74, rh * scale)))
  }
  // Подбираем текстовую метку по виду вложения и добавляем подпись новой строкой. Это запасной
  // текст образца для сообщения без рисуемой картинки.
  private static func label(_ m: Message) -> String {
    let title: [MessageKind: String] = [
      .photo: "▧ Фотография", .video: "▶ Видео", .voice: "◉ Голосовое сообщение",
      .round: "◉ Видеокружочек", .gif: "GIF", .sticker: "Стикер",
    ]
    return (title[m.kind] ?? "") + (m.caption.isEmpty ? "" : "\n" + m.caption)
  }
  // Проверяем, состоит ли текст только из подходящих цветных знаков, и выбираем размер по их
  // числу. Обычный текст тогда сохраняет исходный шрифт.
  private static func largeEmojiFontSize(_ text: String) -> CGFloat? {
    guard !text.isEmpty else { return nil }
    var count = 0
    var maxLine = 0
    var line = 0
    var lines = 1
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
    let length = max(max(maxLine, line), lines)
    let multipliers: [CGFloat] = [1, 0.84, 0.69, 0.53, 0.46, 0.38, 0.32, 0.27, 0.24]
    return floor(94 * (length <= multipliers.count ? multipliers[length - 1] : 0.21))
  }
  // Находим строку, которая пересекает заданную высоту, и возвращаем её первую позицию и остаточный
  // сдвиг. Так можно сверить точку чтения после переноса строк.
  func lineAnchor(y: CGFloat) -> (Int, CGFloat)? {
    guard let i = tops.indices.first(where: { tops[$0] + lineHeights[$0] > y }) ?? tops.indices.last
    else { return nil }
    return (starts[i], tops[i] - y)
  }
  struct AccessibleLine {
    let start: Int
    let text: String
    let frame: CGRect
  }
  // Ищем начало видимого диапазона и берём до заданного числа строк из готовой геометрии.
  // Измерять весь текст заново для проверки специальных возможностей не нужно.
  func accessibleLines(from lower: CGFloat, to upper: CGFloat, limit: Int) -> [AccessibleLine] {
    guard !tops.isEmpty, limit > 0 else { return [] }
    var lo = 0
    var hi = tops.count
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
              x: textInset, y: tops[i], width: max(1, width - textInset - 10),
              height: lineHeights[i])))
      }
      i += 1
    }
    return result
  }
  // Под общей защитой рисуем указанную часть, используя сохранённые строки и границы. Проверка
  // закрытия и номера части защищает от рисования уже освобождённого блока.
  func draw(part: Int, in context: CGContext) {
    lock.lock()
    defer { lock.unlock() }
    guard blocks.indices.contains(part), !closed else { return }
    let b = blocks[part]
    let fill =
      (message.direction == .outgoing
      ? (mediaRect != nil
        ? UIColor(red: 239 / 255, green: 1, blue: 222 / 255, alpha: 1) : KandinskyPalette.outgoing)
      : .white).cgColor
    context.setFillColor(fill)
    if message.kind != .round && message.kind != .sticker && emojiFontSize == nil {
      let rect = CGRect(x: 0, y: -b.offsetY, width: width, height: height)
      if mediaRect == nil {
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
        + CGFloat(CTLineGetPenOffsetForFlush(lines[i], rtl ? 1 : 0, Double(width - textInset - 10)))
      context.textPosition = CGPoint(x: x, y: b.height - (tops[i] - b.offsetY) - ascents[i])
      CTLineDraw(lines[i], context)
    }
    if part == blocks.count - 1 {
      if emojiFontSize == nil && !(mediaRect != nil && text.isEmpty) {
        let baseline =
          captionStampInline
          ? b.height - (tops.last! - b.offsetY) - ascents.last!
          : compact ? b.height - tops[0] - ascents[0] - 3 : 7
        context.textPosition = CGPoint(x: width - stampWidth - 11, y: baseline)
        CTLineDraw(stamp, context)
      }
    }
    context.restoreGState()
    if emojiFontSize != nil, part == blocks.count - 1 {
      let w = CGFloat(CTLineGetTypographicBounds(mediaStamp, nil, nil, nil))
      let box = CGRect(x: max(0, width - w - 10), y: b.height - 18, width: w + 10, height: 18)
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
  // Решаем, нужна ли отдельная метка на вложении. У фото с подписью время уже может находиться в
  // текстовой части.
  var hasMediaStamp: Bool {
    guard mediaRect != nil else { return false }
    return [.video, .gif, .round, .sticker].contains(message.kind) || text.isEmpty
  }
  // Собираем прямоугольники меток под защитой от закрытия. Они нужны, чтобы сравнить маленькие
  // нарисованные области с полным образцом.
  var mediaStampRegions: [CGRect] {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, hasMediaStamp, let rect = mediaRect else { return [] }
    var regions: [CGRect] = []
    // Измеряем строку и добавляем прямоугольник с запасом по ширине. По этому списку проверяем,
    // какой участок должен занять каждая метка на картинке.
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
  // Рисуем время, длительность и отметку выключенного звука по виду вложения. Берём сохранённые
  // данные под той же защитой, что и основной рисунок.
  func drawMediaStamp(in context: CGContext) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, let rect = mediaRect else { return }
    // Рисуем тёмную округлую подложку, переворачиваем ось для текста и выводим строку с отступом.
    // После неё возвращаем настройки рисования для соседних элементов.
    func pill(_ line: CTLine, x: CGFloat, y: CGFloat) {
      let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      let box = CGRect(x: x, y: y, width: w + 10, height: 18)
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
    if message.kind == .round {
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
  // Однократно закрываем образец и очищаем подготовленные строки, высоты и части под общей
  // защитой. Поздний вызов рисования тогда не получит старый рисунок.
  func close() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closed = true
    lines.removeAll()
    blocks.removeAll()
    tops.removeAll()
    starts.removeAll()
    ascents.removeAll()
    lineHeights.removeAll()
  }
}
