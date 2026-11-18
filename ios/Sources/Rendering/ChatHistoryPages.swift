import UIKit

extension ChatScrollHost {
  /// Перед применением проверяет поколение открытия, чтобы поздний ответ не заменил уже выбранный другой
  /// чат.
  func open(chatID: ChatID, repository: ChatRepository, anchor: ReadingAnchor?) async throws {
    initialIndexReady = false
    self.chatID = chatID
    self.repository = repository
    pages = PageWindow(chatID: chatID, repository: repository)
    pendingAnchor = anchor ?? ReadingAnchor()
    generation += 1
    let ticket = generation
    let rows = try await repository.index(chatID: chatID)
    let prepared = try await Task.detached(priority: .userInitiated) {
      let value = HistoryIndex(dayGap: 36)
      _ = try value.replace(rows: rows, anchor: ReadingAnchor(), viewport: 0)
      return value
    }.value
    guard !closed, ticket == generation else { return }
    index = prepared
    initialIndexReady = true
    motionProbe.start(self)
    setGeometry(anchor: pendingAnchor ?? ReadingAnchor())
    schedule()
  }

  func apply(_ delta: MessageDelta) {
    guard let repository, let chatID, !closed else { return }
    if metadataTask == nil, patchStudioRows(delta) { return }
    mediaGallery?.apply(delta)
    playback?.apply(delta)
    let anchor =
      delta.reason == .localSend && delta.inserted.contains { $0.direction == .outgoing }
      ? ReadingAnchor(followsBottom: true)
      : ReadingAnchorResolver.afterRemoving(
        readingAnchor(), rows: index.rows, removed: Set(delta.removedIDs))
    pendingAnchor = anchor
    generation += 1
    let ticket = generation
    metadataTask?.cancel()
    metadataTask = Task {
      defer { if ticket == generation { metadataTask = nil } }
      do {
        let rows = try await repository.index(chatID: chatID)
        let previous = Dictionary(uniqueKeysWithValues: index.rows.map { ($0.messageID, $0) })
        let prepared = try await Task.detached(priority: .userInitiated) {
          let value = HistoryIndex(dayGap: 36)
          let merged = rows.map { r in
            if let old = previous[r.messageID], old.revision == r.revision { return old }
            return r
          }
          _ = try value.replace(rows: merged, anchor: anchor, viewport: 0)
          return value
        }.value
        guard !Task.isCancelled, !closed, ticket == generation else { return }
        let retained = loaded.values.filter { row in
          guard let position = prepared.position(of: row.id), let meta = prepared.row(at: position)
          else { return false }
          return meta.revision == row.revision && meta.order == row.order
        }
        pageTask?.cancel()
        pageTask = nil
        pages?.close()
        pages = PageWindow(chatID: chatID, repository: repository)
        pages?.seedKnownRows(retained)
        loaded = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        index = prepared
        initialIndexReady = true
        setGeometry(anchor: anchor)
        onCountChanged?(index.rows.count)
        schedule()
      } catch { if !Task.isCancelled { onError?(error) } }
    }
  }

  /// Обновляем карточку на месте, когда меняется только ход генерации. Так история остаётся на месте.
  private func patchStudioRows(_ delta: MessageDelta) -> Bool {
    guard delta.inserted.isEmpty, delta.removedIDs.isEmpty, !delta.updated.isEmpty,
      delta.updated.allSatisfy({ row in
        guard row.studioGeneration != nil || loaded[row.id]?.studioGeneration != nil,
          let pos = index.position(of: row.id), let entry = index.row(at: pos)
        else { return false }
        return entry.order == row.order && entry.savedAtMs == row.savedAtMs
      })
    else { return false }
    let anchor = readingAnchor()
    var heightChanged = false, mediaChanged = false
    for row in delta.updated {
      index.refreshRevision(row)
      pages?.refreshKnownRow(row)
      guard let old = loaded[row.id], old.revision < row.revision else { continue }
      mediaChanged = mediaChanged || old.attachments != row.attachments
      loaded[row.id] = row
      let resource = PreparedText(message: row, key: key(row))
      cache.insert(resource)
      let height = Double(resource.height + 4)
      if let previous = index.height(of: row.id), abs(previous - height) > 0.5 {
        _ = try? index.updateHeight(
          id: row.id, height: height, anchor: anchor, viewport: Double(bounds.height))
        heightChanged = true
      }
    }
    if mediaChanged {
      mediaGallery?.apply(delta)
      playback?.apply(delta)
    }
    if heightChanged { setGeometry(anchor: anchor, preservingMotion: true) }
    schedule()
    return true
  }

  func requestPage(center: OrderKey) {
    guard pageTask == nil, let pages, let chatID else { return }
    pageRequests += 1
    if MetricsRuntime.enabled { MetricsRuntime.recorder.peak("page_requests", pageRequests) }
    pageTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.pages === pages { pageTask = nil } }
      do {
        _ = try await pages.request(PageRequest(chatID: chatID, anchor: center, direction: .around))
        guard !closed, !Task.isCancelled, self.pages === pages else { return }
        loaded = Dictionary(uniqueKeysWithValues: pages.loadedRows.map { ($0.id, $0) })
        schedule()
      } catch {
        if !Task.isCancelled {
          finishInitialFrame(.failure(error))
          onError?(error)
        }
      }
    }
  }
}
