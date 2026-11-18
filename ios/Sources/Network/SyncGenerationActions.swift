// Находит активное задание и передаёт действия над одним запросом или результатом. Перед
// отправкой сопоставляет местный номер с номером сервера.

import Foundation

extension NetworkSync {
  // Ищет самое свежее входящее сообщение чата со статусом ожидания или работы. По этой строке
  // экран выбирает, какой генерации показать управление.
  func activeGeneration(chat: Int64) async throws -> MessageID? {
    try await store.perform { db in
      // Обе платформы сохраняют дополнительные данные в одинаковой компактной записи
      try db.rows(
        """
        SELECT m.id FROM messages m JOIN net_message_metadata n ON n.localID=m.id
        WHERE m.chatId=? AND m.direction='incoming'
          AND (instr(n.payload, '"kandinskyStatus":"queued"')>0
            OR instr(n.payload, '"kandinskyStatus":"running"')>0)
        ORDER BY m.sortKey DESC,m.id DESC LIMIT 1
        """, [.integer(chat)]
      ).first?["id"]?.optionalInt
    }
  }
  // Читает номер сервера только для сообщения указанного чата и ещё открытого сеанса. Без сверки
  // действие могло бы обратиться не к той строке.
  private func generationPath(chat: Int64, message: MessageID) async throws -> String {
    guard !closed else { throw RepoError.io }
    let serverID = try await store.perform { db in
      try db.rows(
        "SELECT n.serverID FROM net_messages n JOIN messages m ON m.id=n.localID WHERE n.localID=? AND m.chatId=?",
        [.integer(message), .integer(chat)]
      ).first?["serverID"]?.optionalInt
    }
    guard let serverID, !closed else { throw RepoError.notFound }
    return "/v1/kandinsky/threads/\(chat)/generations/\(serverID)"
  }
  // Выбирает удаление всего запроса или конкретного файла и проверяет допустимый номер файла.
  // После успеха просит перечитать чат, если соединение открыто, чтобы экран быстрее увидел
  // очистку.
  func deleteGenerationContent(chat: Int64, message: MessageID, blob: String?) async throws {
    let path = try await generationPath(chat: chat, message: message)
    if let blob, !RemoteMediaLocation.validBlobID(blob) { throw RepoError.invalidInput }
    let query = blob.map { "target=result&blob=" + $0 } ?? "target=prompt"
    _ = try await api.json(path + "?" + query, method: "DELETE")
    if resumed, !closed { try? await send(["type": "kandinsky.open", "chatId": chat]) }
  }
  // Отправляет выбранную причину по проверенному адресу задания. Жалоба должна относиться к
  // результату сервера, поэтому местный номер сначала переводится.
  func reportGeneration(chat: Int64, message: MessageID, reason: StudioReportReason) async throws {
    let path = try await generationPath(chat: chat, message: message)
    _ = try await api.json(
      path + "/report", body: JSONEncoder().encode(["reason": reason.rawValue]))
  }
  // Собирает действие, номер попытки и выбранного результата, при полном повторе сохраняет номер
  // до отправки. Ответ пишет в базу перед выдачей экрану, чтобы потеря ответа не привела к новой
  // работе.
  func generationAction(
    chat: Int64, message: MessageID, action: StudioGenerationAction, operation: UUID?,
    slot: StudioGeneration.Slot? = nil
  ) async throws {
    let path = try await generationPath(chat: chat, message: message)
    let retryKey = action == .retry && slot == nil ? "generationRetry:\(chat):\(message)" : nil
    let operationID: String?
    if let retryKey {
      // После потери ответа берём тот же номер попытки из базы телефона.
      operationID = try await store.perform { [cache] db in
        try cache.pendingRetry(db, key: retryKey, proposed: operation)
      }
    } else {
      operationID = operation?.uuidString.lowercased()
    }
    var body = ["action": slot == nil ? action.rawValue : "retry_slot"]
    body["operation"] = operationID
    body["slot"] = slot?.id
    body["expected_run"] = slot?.runId
    let data = try await api.json(
      path + "/action",
      body: JSONSerialization.data(withJSONObject: body))
    guard !closed else { return }
    let deltas = try await store.perform { [cache] in
      try cache.generationRows(
        $0, chat: chat, data: data, retryKey: retryKey, operation: operationID)
    }
    if !closed { ui.offer(deltas) }
  }
}
