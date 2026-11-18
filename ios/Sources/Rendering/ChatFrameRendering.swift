// Подготовка кадра ленты на айфоне сшивает измеренные строки, отрисовку файлов и действия
// доступности. Она переиспользует готовые части, а незнакомый участок просит прочитать порцией.
// Срочные видимые строки получают место раньше далёких.

import UIKit

final class PreparedChatRowWindow {
  struct Key: Equatable {
    let range: Range<Int>
    let geometryRevision: Int
    let layoutRevision: Int
    let viewWidth: CGFloat
    let layoutWidth: CGFloat
    let fontSize: Int
    let screenScale: Int
  }

  struct Row {
    let message: Message
    let layout: PreparedText
    let origin: CGPoint
  }

  private struct FragmentWindow {
    let snapshot: SceneSnapshot
    let topAfter: CGFloat
    let topAtMost: CGFloat
    let bottomAtLeast: CGFloat
    let bottomBefore: CGFloat
  }

  let key: Key
  let rows: [Row]
  private var fragmentWindow: FragmentWindow?

  // Закрепляем готовые строки за ключом их геометрии и оформления. Такое окно можно использовать
  // между кадрами, пока размеры и нужный диапазон совпадают.
  init(key: Key, rows: [Row]) {
    self.key = key
    self.rows = rows
  }

  // Собираем ограниченное число видимых частей строк и запоминаем границы, внутри которых состав
  // не меняется. При малом сдвиге возвращаем прежний снимок вместо повторного перебора.
  func snapshot(top: CGFloat, bottom: CGFloat, ticket: Int) -> SceneSnapshot {
    if let window = fragmentWindow, window.snapshot.ticket == ticket,
      top > window.topAfter, top <= window.topAtMost,
      bottom >= window.bottomAtLeast, bottom < window.bottomBefore
    {
      return window.snapshot
    }

    var fragments: [SceneFragment] = []
    var topAfter = -CGFloat.infinity
    var topAtMost = CGFloat.infinity
    var bottomAtLeast = -CGFloat.infinity
    var bottomBefore = CGFloat.infinity
    // Пока края окна не пересекли фрагмент, состав слоёв остаётся прежним.
    visibleFragments: for row in rows {
      for (part, block) in row.layout.blocks.enumerated() {
        let y = row.origin.y + block.offsetY
        let end = y + block.height
        if end < top {
          topAfter = max(topAfter, end)
        } else if y > bottom {
          bottomBefore = min(bottomBefore, y)
        } else {
          topAtMost = min(topAtMost, end)
          bottomAtLeast = max(bottomAtLeast, y)
          fragments.append(
            SceneFragment(prepared: row.layout, part: part,
              frame: CGRect(x: row.origin.x, y: y, width: row.layout.width, height: block.height)))
          if fragments.count == 128 { break visibleFragments }
        }
      }
    }
    let snapshot = SceneSnapshot(ticket: ticket, fragments: fragments)
    fragmentWindow = FragmentWindow(
      snapshot: snapshot, topAfter: topAfter, topAtMost: topAtMost,
      bottomAtLeast: bottomAtLeast, bottomBefore: bottomBefore)
    return snapshot
  }
}

extension ChatScrollHost {
  // Составляем ключ по редакции сообщения, месту по ширине, размеру шрифта и масштабу. Для фото и
  // карточек учитываем пропорции, иначе готовая раскладка могла бы оказаться от другой ширины.
  func key(_ row: Message) -> TextLayoutKey {
    let viewport = lastSize.width > 0 ? lastSize.width : bounds.width
    let visual =
      !row.attachments.isEmpty && [.photo, .video, .round, .gif, .sticker].contains(row.kind)
    let diameter = row.kind == .round ? min(212, Int(viewport - 40)) : nil
    let width: Int
    if let generation = row.studioGeneration {
      width =
        (generation.isActive || generation.slots?.isEmpty == false)
        ? Int(min(304, viewport - 20, generation.ratio < 1 ? viewport * 0.70 + 8 : 304))
        : Int(min(316, viewport - 24))
    } else if row.direction == .incoming, row.attachments.count == 1,
      row.kind == .photo || row.kind == .video, let attachment = row.attachments.first
    {
      let portrait =
        attachment.orientation >= 5
        ? attachment.rawHeight < attachment.rawWidth : attachment.rawWidth < attachment.rawHeight
      width = Int(min(304, viewport - 20, portrait ? viewport * 0.70 + 8 : 304))
    } else {
      width =
        visual
        ? min(row.kind == .round ? (diameter! + 36) : 304, Int(viewport - 40))
        : min(280, Int((viewport * 0.76).rounded(.up)))
    }
    return TextLayoutKey(
      messageID: row.id, revision: row.revision, width: max(60, width), fontSize: max(3, fontSize),
      scale: Int(self.window?.screen.scale ?? UIScreen.main.scale), roundDiameter: diameter)
  }

  // Выбираем левый край по стороне сообщения и виду содержимого. Карточки и кнопки имеют
  // отдельные поля, чтобы действие и рисунок остались на одной линии.
  func rowLeft(_ row: Message, _ prepared: PreparedText) -> CGFloat {
    if let card = prepared.generationCard {
      return card.isBatch || card.generation.isActive ? 10 : 6
    }
    if !prepared.mediaActions.isEmpty { return 10 }
    let media = prepared.mediaRect != nil
    return row.direction == .outgoing
      ? bounds.width - prepared.width - (media ? 6 : 12) : (media ? 6 : 18)
  }

  // Принимаем измерения только для текущей редакции и ширины. Применяем их одним пересчётом,
  // сохраняя место чтения и не притягивая к последнему сообщению во время жеста.
  private func applyPreparedHeights() {
    guard !pendingHeights.isEmpty else { return }
    let updates = pendingHeights
    pendingHeights.removeAll(keepingCapacity: true)
    var anchor = readingAnchor()
    if isTracking || isDragging || isDecelerating || compositorFlight != nil {
      // Фоновая разметка не должна притягивать к концу истории во время жеста или инерции.
      anchor.followsBottom = false
    }
    var changed = false
    for (id, update) in updates {
      guard let row = loaded[id], key(row) == update.key, let old = index.height(of: id),
        old != update.height
      else { continue }
      if (try? index.updateHeight(
        id: id, height: update.height, anchor: anchor, viewport: Double(bounds.height))) != nil
      {
        changed = true
      }
    }
    if changed { setGeometry(anchor: anchor, preservingMotion: true) }
  }

  // Берём готовые строки, а пропущенную порцию просим у хранилища рядом с экраном. Отменяем
  // далёкие расчёты и сначала готовим видимые. Полностью готовое окно удерживаем для следующих
  // кадров.
  private func preparedRows(in range: Range<Int>, current: Range<Int>) -> PreparedChatRowWindow {
    let windowKey = PreparedChatRowWindow.Key(
      range: range, geometryRevision: index.geometryRevision, layoutRevision: cache.revision,
      viewWidth: bounds.width, layoutWidth: lastSize.width, fontSize: fontSize,
      screenScale: Int(window?.screen.scale ?? UIScreen.main.scale))
    if let preparedRowWindow, preparedRowWindow.key == windowKey { return preparedRowWindow }
    preparedRowWindow = nil

    let pivot = current.lowerBound + current.count / 2
    var nearestMissingPosition: Int?
    var nearestMissingDistance = Int.max
    let scrollTop = Double(viewportOffsetY)
    let scrollBottom = scrollTop + Double(bounds.height)
    var wanted = Set<TextLayoutKey>(minimumCapacity: range.count)
    var visibleLayouts = Set<TextLayoutKey>()
    var ready: [PreparedChatRowWindow.Row] = []
    var missingLayouts: [(row: Message, key: TextLayoutKey, distance: Double)] = []
    ready.reserveCapacity(range.count)
    for position in range {
      let meta = index.rows[position]
      guard let row = loaded[meta.messageID] else {
        let distance = abs(position - pivot)
        if distance < nearestMissingDistance {
          nearestMissingDistance = distance
          nearestMissingPosition = position
        }
        continue
      }
      #if DEBUG
        onPreparedRowLookup?(row.id)
      #endif
      let layoutKey = key(row)
      wanted.insert(layoutKey)
      if let layout = cache.value(layoutKey) {
        if let top = index.top(of: row.id) {
          ready.append(.init(message: row, layout: layout,
            origin: CGPoint(x: rowLeft(row, layout), y: CGFloat(top))))
        }
      } else {
        if current.contains(position) { visibleLayouts.insert(layoutKey) }
        guard inFlight[layoutKey] == nil else { continue }
        #if DEBUG
          onLayoutPriorityDistance?(row.id)
        #endif
        let top = index.top(of: row.id) ?? 0
        let distance = max(0, scrollTop - (top + meta.estimatedHeight), top - scrollBottom)
        missingLayouts.append((row, layoutKey, distance))
      }
    }
    if let nearestMissingPosition { requestPage(center: index.rows[nearestMissingPosition].order) }
    for (key, token) in inFlight where !wanted.contains(key) { token.cancel() }
    // Ближайшая строка первой попадает в очередь. Готовые строки уже идут в порядке истории.
    worker.prioritizeVisible(visibleLayouts)
    missingLayouts.sort { $0.distance < $1.distance }
    // За кадр добавляем немного дальних строк, оставляя место следующему жесту.
    var offscreenRequests = 0
    for (row, layoutKey, _) in missingLayouts {
      if !visibleLayouts.contains(layoutKey) {
        guard offscreenRequests < 8 else { continue }
        offscreenRequests += 1
      }
      let ticket = scene.ticket
      inFlight[layoutKey] = worker.prepare(message: row, key: layoutKey, ticket: ticket) {
        [weak self] ticket, resource in
        MainActor.assumeIsolated {
          guard let self else {
            resource?.close()
            return
          }
          self.inFlight.removeValue(forKey: layoutKey)
          guard let resource else {
            self.schedule()
            return
          }
          guard self.scene.accept(resource, ticket: ticket) else { return }
          self.cache.insert(resource)
          if let current = self.loaded[row.id], self.key(current) == resource.key,
            self.index.position(of: row.id) != nil
          {
            self.pendingHeights[row.id] = (resource.key, Double(resource.height + 4))
          }
          self.schedule()
        }
      }
    }
    // Полностью готовое окно можно сдвигать. Частичное нужно пересматривать, пока грузятся строки.
    let window = PreparedChatRowWindow(key: windowKey, rows: ready)
    if ready.count == range.count { preparedRowWindow = window }
    return window
  }

  // Согласуем новые высоты, строки, даты, вложения и доступные действия в одном кадре. Держим
  // запас по направлению движения, но оставляем место всему видимому экрану. Когда сцена готова,
  // завершаем ожидание первого кадра.
  func render() {
    guard bounds.width > 0, bounds.height > 0, !closed else { return }
    let mediaBefore = min(bounds.height * 3, CGFloat(preparation.mediaBefore))
    let mediaAfter = min(bounds.height * 3, CGFloat(preparation.mediaAfter))
    // Новые границы истории и положения сохранённых фрагментов применяются в одном проходе
    applyPreparedHeights()
    motionProbe.noteRender()
    accessibilityUsed.removeAll(keepingCapacity: true)
    let renderToken = MetricsRuntime.recorder.begin()
    defer {
      if MetricsRuntime.enabled {
        MetricsRuntime.recorder.end("scene_cpu_ms", renderToken)
        MetricsRuntime.recorder.peak("loaded_messages", loaded.count)
        MetricsRuntime.recorder.peak("history_rows", index.rows.count)
        MetricsRuntime.recorder.peak("scene_fragments", scene.metrics.liveFragments)
        MetricsRuntime.recorder.peak("active_gif_owners", scene.metrics.activeFrameClocks)
        MetricsRuntime.recorder.peak("text_cache_bytes", cache.bytes)
        MetricsRuntime.recorder.peak("image_owned_bytes", viewerMedia?.bytesUsed ?? 0)
      }
    }
    // Подготавливаем соседнее содержимое по расстоянию, поскольку число коротких строк не задаёт нужный запас прокрутки
    let viewportTop = max(0, viewportOffsetY),
      preparedTop = max(0, viewportTop - max(CGFloat(preparation.before), mediaBefore))
    let preparedBottom = viewportTop + bounds.height + max(CGFloat(preparation.after), mediaAfter)
    let runway = index.visible(
      offset: Double(preparedTop), height: Double(preparedBottom - preparedTop), overscan: 0)
    let current = index.visible(
      offset: Double(viewportTop), height: Double(bounds.height), overscan: 0)
    // Соседние строки не должны занять все сто двадцать восемь мест до добавления текущего экрана
    let start = max(runway.lowerBound, current.upperBound - 128)
    let range = start..<max(current.upperBound, min(runway.upperBound, start + 128))
    let window = preparedRows(in: range, current: current)
    let snapshot = window.snapshot(top: preparedTop, bottom: preparedBottom, ticket: scene.ticket)
    var elements: [Any] = days.apply(
      index.days(offset: Double(viewportOffsetY), height: Double(bounds.height)), offset: 0,
      width: bounds.width, container: plane, studio: onStudioGenerationAction != nil
    ).map { $0 }
    for row in window.rows {
      let resource = row.layout
      let x = row.origin.x, rowY = row.origin.y, viewY = rowY - viewportOffsetY
      appendRowAccessibility(row.message, layout: resource, x: x, rowY: rowY, viewY: viewY,
        elements: &elements)
    }
    scene.viewport = CGRect(
      x: 0, y: viewportOffsetY + overlayTop, width: bounds.width,
      height: max(0, bounds.height - overlayTop - overlayBottom))
    scene.imageViewport = CGRect(
      x: 0, y: viewportOffsetY, width: bounds.width, height: bounds.height)
    scene.imagePreparationViewport = CGRect(
      x: 0, y: viewportOffsetY - mediaBefore, width: bounds.width,
      height: bounds.height + mediaBefore + mediaAfter)
    scene.apply(snapshot)
    for (id, itemIndex, rect, label) in scene.loadActions()
    where rect.maxY > viewportOffsetY && rect.minY < viewportOffsetY + bounds.height {
      let e = accessibilityElement(
        "media.load.\(id)" + (itemIndex == 0 ? "" : ".\(itemIndex)"), key: nil, frame: rect
      ) {
        let e = KandinskyActionElement(accessibilityContainer: plane)
        e.accessibilityTraits = .button
        e.activate = { [weak self, weak e] in
          guard let self, let e else { return }
          _ = self.scene.performLoadAction(
            at: CGPoint(
              x: e.accessibilityFrameInContainerSpace.midX,
              y: e.accessibilityFrameInContainerSpace.midY))
        }
        return e
      }
      if e.accessibilityLabel != label { e.accessibilityLabel = label }
      elements.append(e)
    }
    updateInlinePlayer()
    if let surface = playerSurface, surface.superview === plane { elements.append(surface) }
    publishAccessibility(elements)
    publishInitialFrame(snapshot.fragments)
  }
}
