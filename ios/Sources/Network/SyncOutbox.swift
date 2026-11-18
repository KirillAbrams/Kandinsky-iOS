// Отправляет сохранённые команды по одной порции и ждёт подтверждения. При обрыве база сохраняет
// команды, чтобы следующий канал мог повторить их с теми же номерами.

import Foundation

struct OutboxState {
  var outboxNeedsFlush = false
  var outboxTask: Task<Void, Never>?
  var acknowledgmentTimeout: Task<Void, Never>?
  var pendingRequestID: String?
  var pendingOperationIDs: [String] = []
}

extension NetworkSync {
  // Отмечает необходимость отправки после запуска связи и просит подтвердить сохранённую границу.
  // Если очередь уже занята, новый проход начнётся после завершения текущего.
  func kick() {
    guard resumed, active else { return }
    outbox.outboxNeedsFlush = true
    acknowledgeSavedCursor()
    sendNextBatch()
  }
  // Читает ограниченную порцию команд и готовит либо одно удаление, либо сообщения. Удерживает
  // номер незавершённого запроса, различает окончательный отказ и обрыв и не отправляет
  // подготовленные данные в сменившийся канал.
  private func sendNextBatch() {
    guard outbox.outboxTask == nil, outbox.pendingRequestID == nil, resumed else { return }
    let connectionID = connectionEpoch
    outbox.outboxNeedsFlush = false
    outbox.outboxTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if connectionID == connectionEpoch {
          outbox.outboxTask = nil
          if outbox.outboxNeedsFlush, outbox.pendingRequestID == nil { sendNextBatch() }
        }
      }
      do {
        let rows = try await store.perform { db in try NetworkJournal.readyOperations(db) }
        guard connectionID == connectionEpoch, resumed, !rows.isEmpty else { return }

        if rows[0]["action"]!.string == "delete" {
          let id = rows[0]["id"]!.string
          let value = try WireObject(data: Data(rows[0]["payload"]!.string.utf8))
          let client = try value.string("targetClientId")
          let user = profile.userId
          let server = try await store.perform { db in
            try db.rows(
              "SELECT serverID FROM net_messages WHERE clientID=? AND senderID=?",
              [.text(client), .integer(user)]
            ).first?["serverID"]?.optionalInt
          }
          guard connectionID == connectionEpoch, resumed, let server else { return }
          outbox.pendingRequestID = id
          outbox.pendingOperationIDs = [id]
          timeout(id, connectionID)
          try await send([
            "type": "delete", "requestId": id, "chatId": try value.int("chatId"),
            "messageId": server,
          ])
          return
        }
        var commands: [SendCommand] = []
        var bytes = 0
        for row in rows {
          // Переходный сервер принимает не больше десяти сообщений в одной порции
          guard row["action"]!.string == "send", commands.count < 10 else { break }
          let data = Data(row["payload"]!.string.utf8)
          if !commands.isEmpty, bytes + data.count > 40000 { break }
          commands.append(try JSONDecoder().decode(SendCommand.self, from: data))
          bytes += data.count
        }
        let messages: [[String: Any]]
        do { messages = try await prepare(commands) } catch let failure as NetworkFailure
          where (400..<500).contains(failure.status) && ![408, 429].contains(failure.status)
        {
          if failure.status == 401 {
            sessionRejected(failure.code)
            return
          }
          let ids = commands.map { $0.operationID.lowercased() }
          let changes = try await store.perform { [cache] in
            try cache.failed($0, ids: ids, code: failure.code)
          }
          ui.offer(changes)
          onStatus?("Не отправлено: " + failure.code)
          Task { [weak self] in self?.kick() }
          return
        }
        guard connectionID == connectionEpoch, resumed, !messages.isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        outbox.pendingRequestID = id
        outbox.pendingOperationIDs = messages.compactMap { $0["clientId"] as? String }
        timeout(id, connectionID)
        try await send(["type": "send", "requestId": id, "messages": messages])
      } catch {
        if connectionID == connectionEpoch, !Task.isCancelled {
          reconnectAfterFailure(connectionID)
        }
      }
    }
  }

  // Назначает предел ожидания только для текущего запроса. Если ответ уже пришёл или начался
  // другой запрос, старый таймер не разрывает соединение.
  private func timeout(_ request: String, _ connectionID: Int) {
    outbox.acknowledgmentTimeout?.cancel()
    outbox.acknowledgmentTimeout = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 15_000_000_000)
      guard !Task.isCancelled, let self, self.outbox.pendingRequestID == request else { return }
      self.reconnectAfterFailure(connectionID)
    }
  }

  // Сначала сохраняет принятие в базе, потом освобождает порцию при совпадении номера и обновляет
  // экран. Следующий проход не начинается до записи прежнего подтверждения.
  func confirmOutgoingMessages(_ data: Data, value: WireObject) async throws {
    let deltas = try await store.perform { [cache] in try cache.accepted($0, data: data) }
    if value.optionalString("requestId") == outbox.pendingRequestID {
      outbox.pendingRequestID = nil
      outbox.pendingOperationIDs = []
      outbox.acknowledgmentTimeout?.cancel()
    }
    ui.offer(deltas)
    kick()
  }

  // Убирает из базы команду с подтверждённым номером и освобождает ожидание только при
  // совпадении. Запоздалый ответ не должен снять ожидание другой команды.
  func confirmDeletion(_ value: WireObject) async throws {
    let id = try value.string("requestId")
    _ = try await store.perform { db in
      try db.execute("DELETE FROM net_outbox WHERE id=? AND action='delete'", [.text(id)])
    }
    if outbox.pendingRequestID == id {
      outbox.pendingRequestID = nil
      outbox.acknowledgmentTimeout?.cancel()
    }
    kick()
  }

  // Сохраняет причину отказа у ожидающих операций, показывает изменения и освобождает отправку.
  // Остальные команды могут продолжиться, а отклонённые сообщения не будут выглядеть принятыми.
  func rejectOutgoingMessages(code: String) async throws {
    let ids = outbox.pendingOperationIDs
    let deltas = try await store.perform { [cache] in try cache.failed($0, ids: ids, code: code)
    }
    ui.offer(deltas)
    outbox.pendingRequestID = nil
    outbox.acknowledgmentTimeout?.cancel()
    onStatus?("Не отправлено: " + code)
    Task { [weak self] in self?.kick() }
  }

  // Отменяет подготовку и ожидание ответа и сбрасывает временные номера. Сохранённые команды
  // остаются в базе, поэтому разрыв не стирает очередь.
  func resetOutbox() {
    outbox.outboxNeedsFlush = false
    outbox.outboxTask?.cancel()
    outbox.outboxTask = nil
    outbox.acknowledgmentTimeout?.cancel()
    outbox.acknowledgmentTimeout = nil
    outbox.pendingRequestID = nil
    outbox.pendingOperationIDs = []
  }
}
