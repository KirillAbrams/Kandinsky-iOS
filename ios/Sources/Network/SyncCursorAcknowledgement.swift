import Foundation

struct CursorAcknowledgement {
  var lookup: Task<Void, Never>?
  var checkAgain = false
  var inFlight: Int64?
}

extension NetworkSync {
  func acknowledgeSavedCursor() {
    guard resumed, cursorAcknowledgement.inFlight == nil else { return }
    if cursorAcknowledgement.lookup != nil {
      cursorAcknowledgement.checkAgain = true
      return
    }
    let epoch = connectionEpoch
    cursorAcknowledgement.lookup = Task { [weak self] in
      guard let self else { return }
      defer {
        if connectionEpoch == epoch {
          cursorAcknowledgement.lookup = nil
          if cursorAcknowledgement.checkAgain {
            cursorAcknowledgement.checkAgain = false
            acknowledgeSavedCursor()
          }
        }
      }
      do {
        let pendingCursor = try await store.perform { [cache] in try cache.cursorAwaitingConfirmation($0) }
        guard let pendingCursor, connectionEpoch == epoch, resumed, !Task.isCancelled else { return }
        cursorAcknowledgement.inFlight = pendingCursor
        try await send(["type": "applied", "cursor": pendingCursor])
      } catch {
        if !Task.isCancelled, connectionEpoch == epoch { reconnectAfterFailure(epoch) }
      }
    }
  }

  func confirmSavedCursor(_ frame: WireObject) async throws {
    let cursor = try frame.int("cursor")
    guard cursorAcknowledgement.inFlight == cursor else { return }
    let epoch = connectionEpoch
    try await store.perform { [cache] db in try cache.state(db, "ackedCursor", String(cursor)) }
    guard connectionEpoch == epoch else { return }
    cursorAcknowledgement.inFlight = nil
    acknowledgeSavedCursor()
  }

  func resetCursorAcknowledgement() {
    cursorAcknowledgement.lookup?.cancel()
    cursorAcknowledgement = CursorAcknowledgement()
  }
}
