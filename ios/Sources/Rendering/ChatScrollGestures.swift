// Жесты ленты на айфоне переводят касание в действие над конкретной строкой или файл. Системные
// события прокрутки ведут измерения движения, готовят следующий кадр и сохраняют место чтения
// после остановки.

import UIKit

extension ChatScrollHost {
  // По вертикальной точке находим строку в указателе и сверяем её фактическую рамку. Касание в
  // пустой части ряда поэтому не откроет сообщение.
  private func hit(_ point: CGPoint) -> (Message, CGRect)? {
    let anchor = index.anchorAt(offset: Double(max(0, point.y)))
    guard let id = anchor.messageID, let row = loaded[id], let top = index.top(of: id),
      let resource = cache.value(key(row))
    else { return nil }
    let frame = CGRect(
      x: rowLeft(row, resource), y: CGFloat(top), width: resource.width, height: resource.height)
    return frame.contains(point) ? (row, frame.offsetBy(dx: 0, dy: -viewportOffsetY)) : nil
  }

  // Сначала проверяем повтор загрузки, затем кнопки карточки и отдельные вложения. Координаты
  // приводим к рамке строки, чтобы соседняя кнопка не получила действие.
  @objc func tapped(_ gesture: UITapGestureRecognizer) {
    let point = gesture.location(in: plane)
    if scene.performLoadAction(at: point) { return }
    if let (row, frame) = hit(point) {
      let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY - viewportOffsetY)
      let prepared = cache.value(key(row))
      if let card = prepared?.generationCard {
        if let retry = card.retryCells.first(where: { $0.frame.contains(local) }) {
          onStudioRetrySlot?(row.id, retry.slot)
        } else if let button = card.controls.first(where: { $0.frame.contains(local) }) {
          onStudioGenerationAction?(row.id, button.action)
        } else if card.isBatch,
          let selected = prepared?.mediaItemRects.firstIndex(where: { $0.contains(local) })
        {
          activateMedia(row, frame: frame, index: selected)
        }
        return
      }
      if let button = prepared?.mediaActions.first(where: { $0.frame.contains(local) }) {
        performMediaAction(
          button.action, row: row, frame: button.frame.offsetBy(dx: frame.minX, dy: frame.minY))
        return
      }
      if onStudioResultDelete != nil, row.direction == .outgoing, row.kind == .text {
        onMessageLongPress?(row, frame)
        return
      }
      let selected = prepared?.mediaItemRects.firstIndex { $0.contains(local) } ?? 0
      activateMedia(row, frame: frame, index: selected)
    }
  }

  // Открываем меню только в начале долгого касания и над найденным сообщением. Следующие вызовы
  // того же удержания второе меню не открывают.
  @objc func longPressed(_ gesture: UILongPressGestureRecognizer) {
    if gesture.state == .began, let (row, frame) = hit(gesture.location(in: plane)) {
      onMessageLongPress?(row, frame)
    }
  }
}

extension ChatScrollHost: UIScrollViewDelegate, UIGestureRecognizerDelegate {
  // Исключаем из жестов истории касания на поверхности проигрывателя. Его кнопки и полоса
  // перемотки обрабатывают ввод сами.
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    guard let surface = playerSurface, let view = touch.view else { return true }
    return !view.isDescendant(of: surface)
  }
  // Отбрасываем уведомление собственного пересчёта, а при внешнем сдвиге прерываем прежнюю
  // инерцию. Снимаем старое ожидающее место и готовим строки уже для новой координаты.
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard !applying else { return }
    if let flight = compositorFlight {
      guard abs(contentOffset.y - flight.trajectory.destination) > 0.5 else { return }
      // Системная прокрутка может сменить положение извне, например при переходе ползунком.
      finishCompositorFlight(at: contentOffset.y, settle: false)
    }
    preparation.observe(
      offset: Double(contentOffset.y), at: scrollClock(), viewport: Double(bounds.height))
    pendingAnchor = nil
    layoutPlane()
    schedule()
  }

  // Тормозим предыдущую инерцию при новом жесте и начинаем измерение кадров. Новый палец получает
  // управление текущим положением.
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    interruptCompositorFlight(braking: true)
    motionProbe.record(.willBeginDragging)
    frameProbe.start()
  }

  // Передаём скорость и расчётную точку остановки в подготовку инерции. Если она подходит
  // движению, следующие вызовы возьмут её вместо системного разгона.
  func scrollViewWillEndDragging(
    _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
    targetContentOffset: UnsafeMutablePointer<CGPoint>
  ) {
    prepareCompositorFlight(velocity: velocity, target: targetContentOffset)
  }

  // Сохраняем итог после обычной системной инерции. Во время своего движения окончание определяет
  // слой, чтобы чтение не записалось раньше времени.
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    guard !applying, compositorFlight == nil else { return }
    settleScrolling()
  }

  // При отпускании запускаем подготовленное движение, если оно есть. Без движения сразу сохраняем
  // положение, а с инерцией ждём её окончания.
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
    let composed = beginCompositorFlight()
    motionProbe.record(.didEndDragging, willDecelerate: composed || willDecelerate)
    if !composed && !willDecelerate { settleScrolling(recordEnd: false) }
  }

  // Возвращаем обычный запас подготовки, закрываем замер и выдаём место чтения. Следующее
  // открытие сможет восстановить последнюю остановку.
  func settleScrolling(recordEnd: Bool = true) {
    if recordEnd { motionProbe.record(.didEndDecelerating) }
    preparation.reset()
    schedule()
    frameProbe.stop()
    onAnchor?(readingAnchor())
  }
}
