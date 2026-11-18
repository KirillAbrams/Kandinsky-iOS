// Разводит по обработчикам входящие события, подтверждения и отказы. Сначала проверяет
// действующее соединение, чтобы поздняя выдача не обновила экран после переподключения.

import Foundation

extension NetworkSync {
  // Разбирает сетевое сообщение, проверяет номер соединения и выбирает действие по виду.
  // Неизвестный вид останавливает обработку, вместо того чтобы пометить непрочитанные данные
  // сохранёнными.
  func receiveFrame(_ data: Data, connectionID: Int) async throws {
    let value = try await api.object(data)
    guard connectionID == connectionEpoch, !Task.isCancelled else { return }
    switch try value.string("type") {
    case "kandinsky.catalog.changed": try await refreshStudioDirectory()
    case "kandinsky.uploads": try acceptStudioTransfers(data)
    case "resumed":
      connectionResumed(connectionID: connectionID)
      try await refreshStudioDirectory()
    case "events": try await applyIncomingEvents(data)
    case "accepted": try await confirmOutgoingMessages(data, value: value)
    case "applied": try await confirmSavedCursor(value)
    case "deleted": try await confirmDeletion(value)
    case "error": try await handleServerError(value)
    case "pong": break
    default: throw RepoError.corrupt
    }
  }

  // При необходимости сначала читает недостающие карточки, затем записывает порцию и уведомляет
  // экран и список. В конце даёт ход удалению файлов и следующим ожидающим отправкам.
  private func applyIncomingEvents(_ data: Data) async throws {
    let fetchedUnknownChats = try await store.perform { [cache] in
      try cache.hasUnknownChats($0, data: data)
    }
    if fetchedUnknownChats {
      let chats = try await api.json("/v1/chats")
      let added = try await store.perform { [cache] in try cache.mergeChats($0, data: chats) }
      ui.offer(added)
    }
    let (changes, directoryChanged) = try await store.perform { [cache] in
      try cache.directoryEvents($0, data: data)
    }
    ui.offer(changes)
    if directoryChanged || fetchedUnknownChats { onStudioRecentChanged?() }
    drainRemovedStudioMedia()
    kick()
  }

  // Разделяет отзыв входа, временный сбой и отказ текущей отправки. Это позволяет либо закрыть
  // сеанс, либо повторить связь, либо показать отказ только в нужном сообщении.
  private func handleServerError(_ value: WireObject) async throws {
    let code = try value.string("code")
    if code == "account_deleted" || code == "invalid_session" {
      sessionRejected(code)
    } else if (value.value["retryable"] as? Bool) == true {
      throw RepoError.io
    } else if value.optionalString("requestId") == outbox.pendingRequestID {
      try await rejectOutgoingMessages(code: code)
    } else {
      throw RepoError.io
    }
  }
}
