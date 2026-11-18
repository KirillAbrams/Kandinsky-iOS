// Место чтения на айфоне хранится по сообщению и смещению от области просмотра. У длинного текста
// запоминаем конкретную строку, чтобы после смены ширины, клавиатуры или высоты сообщения не
// потерять выбранный абзац.

import UIKit

extension ChatScrollHost {
  // Используем ожидающую позицию при ещё не разобранной истории. Иначе снимаем верхнюю видимую
  // точку, отмечаем близость к концу и по готовому тексту сохраняем место внутри строки.
  func readingAnchor(viewport: CGFloat? = nil) -> ReadingAnchor {
    if let pendingAnchor { return pendingAnchor }
    var value = index.anchorAt(offset: Double(max(0, viewportOffsetY + overlayTop)))
    value.followsBottom =
      index.totalHeight - Double(viewportOffsetY + (viewport ?? bounds.height)) < 24
    if let id = value.messageID, let row = loaded[id], let resource = cache.value(key(row)),
      let top = index.top(of: id), row.kind == .text,
      let line = resource.lineAnchor(y: viewportOffsetY + overlayTop - CGFloat(top))
    {
      value.textUTF16Offset = line.0
      value.screenDelta = Double(line.1)
    }
    return value
  }

  // Восстанавливаем низ истории или координату сохранённого символа после нового переноса строк.
  // Если текст ещё не готов, берём приблизительную позицию сообщения и ограничиваем её высотой
  // ленты.
  private func resolved(_ anchor: ReadingAnchor) -> CGFloat {
    if anchor.followsBottom { return CGFloat(max(0, index.totalHeight - Double(bounds.height))) }
    if let id = anchor.messageID, let offset = anchor.textUTF16Offset, let row = loaded[id],
      let prepared = cache.value(key(row)), let y = prepared.y(forUTF16: offset),
      let top = index.top(of: id)
    {
      return max(
        0,
        min(
          CGFloat(index.totalHeight) - bounds.height,
          CGFloat(top) + y - CGFloat(anchor.screenDelta) - overlayTop))
    }
    return max(
      0,
      min(
        max(0, CGFloat(index.totalHeight) - bounds.height),
        CGFloat(index.offset(for: anchor, viewport: Double(max(0, bounds.height - overlayTop))))
          - overlayTop))
  }

  // Обновляем размеры истории и возвращаем сохранённое место с учётом панелей. При сохранении
  // движения переносим его в новые координаты. Иначе пересчёт высот мог бы оборвать инерцию или
  // сдвинуть очередь подготовки.
  func setGeometry(anchor: ReadingAnchor, preservingMotion: Bool = false) {
    motionProbe.record(.geometryWillChange, preservingMotion: preservingMotion)
    defer { motionProbe.record(.geometryDidChange, preservingMotion: preservingMotion) }
    index.configureInsets(top: Double(overlayTop + 8), bottom: Double(overlayBottom + 8))
    applying = true
    let previousOffset = viewportOffsetY
    let size = CGSize(width: bounds.width, height: max(0, CGFloat(index.totalHeight)))
    if contentSize != size { contentSize = size }
    let offset = CGPoint(x: 0, y: resolved(anchor))
    if compositorFlight != nil {
      if preservingMotion {
        rebaseCompositorFlight(to: offset.y)
      } else {
        finishCompositorFlight(at: offset.y, settle: false)
      }
    } else if preservingMotion {
      // Для сохранения инерции меняем начало координат, поскольку обычная установка смещения остановила бы движение
      if bounds.origin != offset { bounds.origin = offset }
    } else {
      setContentOffset(offset, animated: false)
    }
    preparation.rebase(by: Double(viewportOffsetY - previousOffset))
    applying = false
    layoutPlane()
  }

  // Подгоняем область отрисовки по ширине и высоте всей ленты. Размер не меняем, если рамка та
  // же, чтобы не запускать лишнюю раскладку.
  func layoutPlane() {
    let frame = CGRect(
      origin: .zero,
      size: CGSize(width: bounds.width, height: max(bounds.height, contentSize.height)))
    if plane.frame != frame { plane.frame = frame }
  }

  // Сначала снимаем позицию чтения, затем ограничиваем новые отступы доступным окном. После
  // обновления полосы прокрутки возвращаем ту же позицию и готовим кадр заново.
  func updateOverlayInsets(top: CGFloat, bottom: CGFloat) {
    guard top != overlayTop || bottom != overlayBottom else { return }
    let anchor = readingAnchor()
    overlayTop = min(max(0, top), bounds.height)
    overlayBottom = min(max(0, bottom), max(0, bounds.height - overlayTop))
    verticalScrollIndicatorInsets = UIEdgeInsets(
      top: overlayTop, left: 0, bottom: overlayBottom, right: 0)
    setGeometry(anchor: anchor)
    schedule()
  }
}
