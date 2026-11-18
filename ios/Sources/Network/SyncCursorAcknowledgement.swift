// Подтверждает серверу границу уже записанной истории. До ответа держит одну отметку, чтобы два
// подтверждения не обогнали друг друга при обрыве.

import Foundation

struct CursorAcknowledgement {
  var lookup: Task<Void, Never>?
  var checkAgain = false
  var inFlight: Int64?
}

extension NetworkSync {
  // Ищет ещё не подтверждённую границу в базе и отправляет её после возобновления связи.
  // Запоминает номер соединения, чтобы чтение, начатое до переподключения, не отправило ответ в
  // новый канал.
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

  // Принимает только ответ для ожидаемой границы и сначала записывает его в хранилище. Если
  // соединение сохранилось, освобождает отметку и проверяет следующую, чтобы после запуска не
  // подтверждать уже сохранённое снова.
  func confirmSavedCursor(_ frame: WireObject) async throws {
    let cursor = try frame.int("cursor")
    guard cursorAcknowledgement.inFlight == cursor else { return }
    let epoch = connectionEpoch
    try await store.perform { [cache] db in try cache.state(db, "ackedCursor", String(cursor)) }
    guard connectionEpoch == epoch else { return }
    cursorAcknowledgement.inFlight = nil
    acknowledgeSavedCursor()
  }

  // Отменяет незаконченный поиск и очищает ожидание при закрытии соединения. Новому каналу не
  // приходится ждать ответа, который ушёл по старому.
  func resetCursorAcknowledgement() {
    cursorAcknowledgement.lookup?.cancel()
    cursorAcknowledgement = CursorAcknowledgement()
  }
}
