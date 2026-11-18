import UIKit

extension ChatScrollHost {
  func accessibilityElement(
    _ id: String, key: TextLayoutKey?, frame: CGRect, make: () -> UIAccessibilityElement
  ) -> UIAccessibilityElement {
    accessibilityUsed.insert(id)
    let element: UIAccessibilityElement
    if let retained = accessibilityEntries[id], retained.key == key {
      element = retained.element
    } else {
      element = make()
      element.accessibilityIdentifier = id
      accessibilityEntries[id] = AccessibilityEntry(key: key, element: element)
    }
    if element.accessibilityFrameInContainerSpace != frame {
      element.accessibilityFrameInContainerSpace = frame
    }
    return element
  }

  func publishAccessibility(_ elements: [Any]) {
    for id in accessibilityEntries.keys.filter({ !accessibilityUsed.contains($0) }) {
      accessibilityEntries.removeValue(forKey: id)
    }
    let previous = plane.accessibilityElements ?? []
    if !previous.elementsEqual(elements, by: { ($0 as AnyObject) === ($1 as AnyObject) }) {
      plane.accessibilityElements = elements
    }
  }

  func appendRowAccessibility(
    _ row: Message, layout resource: PreparedText, x: CGFloat, rowY: CGFloat,
    viewY: CGFloat, elements: inout [Any]
  ) {
    if playback?.currentMessageID != row.id {
      for (itemIndex, rect) in resource.mediaItemRects.enumerated()
      where rect.maxY + viewY > 0 && rect.minY + viewY < bounds.height && elements.count < 128 {
        let identity = "media.image.\(row.id)" + (itemIndex == 0 ? "" : ".\(itemIndex)")
        let e = accessibilityElement(
          identity, key: resource.key, frame: rect.offsetBy(dx: x, dy: rowY)
        ) {
          let e = KandinskyActionElement(accessibilityContainer: plane)
          e.activate = { [weak self, weak e] in
            guard let self, let e else { return }
            self.activateMedia(
              row,
              frame: e.accessibilityFrameInContainerSpace.offsetBy(
                dx: 0, dy: -self.viewportOffsetY), index: itemIndex)
          }
          e.accessibilityLabel =
            row.kind == .round
            ? "Воспроизвести кружочек"
            : row.attachments[itemIndex].mime.hasPrefix("video/")
              ? "Воспроизвести видео" : "Открыть фотографию"
          e.accessibilityTraits = .button
          if row.canReportStudioMedia, onStudioGenerationAction != nil {
            e.accessibilityCustomActions = [
              UIAccessibilityCustomAction(name: "Пожаловаться на результат") {
                [weak self, weak e] _ in
                guard let self, let e, let show = self.onMessageLongPress else { return false }
                show(row, e.accessibilityFrameInContainerSpace)
                return true
              }
            ]
          }
          return e
        }
        elements.append(e)
      }
    }
    for button in resource.mediaActions
    where button.frame.maxY + viewY > 0 && button.frame.minY + viewY < bounds.height
      && elements.count < 128
    {
      let e = accessibilityElement(
        "media.action.\(button.action.rawValue).\(row.id)", key: resource.key,
        frame: button.frame.offsetBy(dx: x, dy: rowY)
      ) {
        let element = KandinskyActionElement(accessibilityContainer: plane)
        element.accessibilityLabel = button.action.title
        element.accessibilityTraits = .button
        element.activate = { [weak self, weak element] in
          guard let self, let element else { return }
          self.performMediaAction(
            button.action, row: row,
            frame: element.accessibilityFrameInContainerSpace.offsetBy(
              dx: 0, dy: -self.viewportOffsetY))
        }
        return element
      }
      elements.append(e)
    }
    if let card = resource.generationCard {
      let indicators =
        card.isBatch
        ? card.cells.filter { $0.slot.blobId == nil }.map {
          ($0.slot.id, $0.slot.status, $0.slot.progress, $0.frame)
        }
        : card.imageFrame.map {
          [("single", card.generation.stage, card.generation.progress, $0)]
        } ?? []
      for (id, stage, progress, rect) in indicators
      where rect.maxY + viewY > 0 && rect.minY + viewY < bounds.height && elements.count < 128 {
        let identity = "generation.slot.\(row.id).\(id)"
        let e = accessibilityElement(
          identity, key: resource.key, frame: rect.offsetBy(dx: x, dy: rowY)
        ) {
          let element = KandinskyActionElement(accessibilityContainer: plane)
          if let cell = card.retryCells.first(where: { $0.slot.id == id }) {
            element.accessibilityLabel = "Повторить генерацию"
            element.accessibilityTraits = .button
            element.activate = { [weak self] in self?.onStudioRetrySlot?(row.id, cell.slot) }
          } else {
            element.accessibilityLabel = StudioGenerationCard.progressLabel(stage, progress)
            element.accessibilityTraits = .staticText
          }
          return element
        }
        elements.append(e)
      }
      for button in card.controls
      where button.frame.maxY + viewY > 0 && button.frame.minY + viewY < bounds.height
        && elements.count < 128
      {
        let identity = "generation.action.\(button.action.rawValue).\(row.id)"
        let e = accessibilityElement(
          identity, key: resource.key, frame: button.frame.offsetBy(dx: x, dy: rowY)
        ) {
          let element = KandinskyActionElement(accessibilityContainer: plane)
          element.accessibilityLabel = button.action.title
          element.accessibilityTraits = .button
          element.activate = { [weak self] in
            self?.onStudioGenerationAction?(row.id, button.action)
          }
          return element
        }
        elements.append(e)
      }
    }
    if row.kind == .voice {
      if playback?.currentMessageID != row.id {
        let e = accessibilityElement(
          "media.audio.\(row.id)", key: resource.key,
          frame: CGRect(x: x, y: rowY, width: resource.width, height: resource.height)
        ) {
          let e = KandinskyActionElement(accessibilityContainer: plane)
          e.accessibilityLabel = resource.text
          e.accessibilityTraits = .button
          e.activate = { [weak self, weak e] in
            guard let self, let e else { return }
            self.onMessageTap?(
              row, e.accessibilityFrameInContainerSpace.offsetBy(dx: 0, dy: -self.viewportOffsetY)
            )
          }
          return e
        }
        elements.append(e)
      }
      return
    }
    for line in resource.accessibleLines(
      from: max(0, -viewY), to: bounds.height - viewY, limit: max(0, 128 - elements.count))
    {
      let id = line.start == 0 ? "message.\(row.id)" : "message.\(row.id).text.\(line.start)"
      let e = accessibilityElement(
        id, key: resource.key, frame: line.frame.offsetBy(dx: x, dy: rowY)
      ) {
        let e = KandinskyActionElement(accessibilityContainer: plane)
        e.accessibilityLabel = line.text
        e.accessibilityTraits = .staticText
        if onStudioResultDelete != nil, row.direction == .outgoing {
          e.accessibilityTraits = .button
          e.activate = { [weak self, weak e] in
            guard let self, let e else { return }
            self.onMessageLongPress?(
              row, e.accessibilityFrameInContainerSpace.offsetBy(dx: 0, dy: -self.viewportOffsetY)
            )
          }
        }
        if onStudioGenerationAction == nil {
          e.accessibilityCustomActions = [("Копировать запрос", MessageAction.copy)].map {
            name, kind in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
              guard let handler = self?.onMessageAction else { return false }
              handler(row, kind)
              return true
            }
          }
        }
        return e
      }
      elements.append(e)
    }
  }
}
