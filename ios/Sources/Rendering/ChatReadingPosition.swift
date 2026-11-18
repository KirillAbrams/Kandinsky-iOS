import UIKit

extension ChatScrollHost {
  /// Для подготовленного текстового сообщения дополнительно запоминает строку, чтобы изменение переноса
  /// текста не уводило чтение.
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

  /// Учитывает верхнюю и нижнюю панели, чтобы содержимое не смещалось из выбранной точки.
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

  func layoutPlane() {
    let frame = CGRect(
      origin: .zero,
      size: CGSize(width: bounds.width, height: max(bounds.height, contentSize.height)))
    if plane.frame != frame { plane.frame = frame }
  }

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
