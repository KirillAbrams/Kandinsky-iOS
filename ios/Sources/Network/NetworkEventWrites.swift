// Записывает первый снимок сервера, следующие события и страницы истории в базу телефона. Экран
// получает изменения после успешной записи.

import Foundation

extension NetworkStore {
  // Сравнивает карточки до и после применения событий. Удаление скрытого чата тоже требует
  // обновить открытый список, даже если сервер не прислал его карточку.
  func directoryEvents(_ db: SQLiteConnection, data: Data) throws
    -> (changes: [MessageDelta], directoryChanged: Bool)
  {
    let json = try WireObject(data: data)
    let rows = json.value["chats"] == nil ? [] : try json.array("chats")
    let keys = try rows.map { "studioDirectory:\(try WireObject($0).int("id"))" }
    let before = try directoryState(db, keys: keys)
    let changes = try events(db, data: data)
    // Удаление приходит без сводки чата. Открытая панель тоже должна перечитать список.
    let retired = changes.contains { $0.chat.hidden }
    return (changes, try retired || before != directoryState(db, keys: keys))
  }

  // Читает только карточки из переданного набора и сортирует их по ключу. Устойчивый порядок
  // нужен для сравнения, иначе перестановка ответов выглядела бы как изменение.
  private func directoryState(_ db: SQLiteConnection, keys: [String]) throws -> [String] {
    guard !keys.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
    return try db.rows(
      "SELECT key,value FROM net_state WHERE key IN (\(placeholders)) ORDER BY key",
      keys.map { .text($0) }
    ).map { $0["key"]!.string + ":" + $0["value"]!.string }
  }

  // Сверяет версию ответа и владельца, затем записывает чаты, сообщения и номер продолжения за
  // один раз. При ошибке приложение не получит половину начального состояния.
  func bootstrap(_ db: SQLiteConnection, data: Data) throws -> [MessageDelta] {
    let json = try WireObject(data: data)
    return try db.transaction {
      guard try json.int("version") == 1, try json.int("userId") == userID else {
        throw RepoError.corrupt
      }
      var touched: [Int64: Set<Int64>] = [:]
      let removed = try mergeChatRows(
        db, json: json, touched: &touched, limit: StudioRecentPage.catalogLimit)
      for object in try json.array("messages") {
        let wire = try WireObject(object)
        if let id = try merge(db, wire: wire) {
          touched[try wire.int("chatId"), default: []].insert(id)
        }
      }
      try state(db, "cursor", String(try json.int("cursor")))
      try rememberStudioRecent(db, json: json)
      return try deltas(db, touched: touched, removed: removed, reason: .sync)
    }
  }

  // Пропускает уже учтённые события, требует непрерывную последовательность и применяет
  // добавления и удаления. Записывает номер продолжения вместе с данными, чтобы при пропуске или
  // сбое телефон мог запросить события с прежнего места.
  func events(_ db: SQLiteConnection, data: Data) throws -> [MessageDelta] {
    let json = try WireObject(data: data)
    return try db.transaction {
      let current = try cursor(db)
      let objects = try json.array("events")
      var next = current
      var touched: [Int64: Set<Int64>] = [:]
      var removed: [Int64: [Int64]] = [:]
      if let catalog = json.value["chats"] as? [[String: Any]] {
        guard catalog.count <= 128 else { throw RepoError.corrupt }
        if try json.int("cursor") > current {
          for row in catalog { try rememberStudioDirectory(db, chat: WireObject(row)) }
        }
        let missing = try catalog.filter { row in
          let id = try WireObject(row).int("id")
          return try db.scalar("SELECT count(*) FROM chats WHERE id=?", [.integer(id)]) == 0
        }
        if !missing.isEmpty {
          removed = try mergeChatRows(db, json: WireObject(["chats": missing]), touched: &touched)
        }
      }
      for object in objects {
        let event = try WireObject(object)
        let seq = try event.int("seq")
        guard seq > 0 else { throw RepoError.corrupt }
        if seq <= next { continue }
        guard seq == next + 1 else { throw RepoError.corrupt }
        next = seq
        let chat = try event.int("chatId")
        let kind = try event.string("kind")
        if kind == "kandinsky.retired" {
          if let ids = try retireStudioThread(db, chat: chat) {
            touched[chat] = []
            removed[chat, default: []] += ids
          }
          continue
        }
        if touched[chat] == nil { touched[chat] = [] }
        removed[chat, default: []] += try ChatServerState.applyState(
          db, chat: chat, value: event.value["chatState"])
        for raw in (event.value["removedMedia"] as? [[String: Any]] ?? []).prefix(10) {
          guard let blob = raw["blobId"] as? String, let preview = raw["previewBlobId"] as? String,
            let removal = StudioMediaRemoval(blob: blob, preview: preview)
          else { throw RepoError.corrupt }
          try state(db, removal.key, removal.preview)
        }
        switch kind {
        case "message":
          let message = try WireObject(event.value["message"] as Any)
          let known = try !db.rows(
            "SELECT 1 FROM net_messages WHERE serverID=?", [.integer(try message.int("id"))]
          ).isEmpty
          if let id = try merge(db, wire: message) { touched[chat, default: []].insert(id) }
          if !known, try message.int("senderId") != userID,
            try message.int("seq")
              > (Int64(
                db.rows("SELECT value FROM net_state WHERE key=?", [.text("summarySeq:\(chat)")])
                  .first?["value"]?.string ?? "0") ?? 0)
          {
            try db.execute(
              "UPDATE chats SET unreadCount=unreadCount+1 WHERE id=?", [.integer(chat)])
          }
        case "deleted":
          try db.execute(
            "INSERT OR IGNORE INTO net_tombstones VALUES(?,?)",
            [.integer(try event.int("messageId")), .integer(chat)])
          try db.execute(
            "DELETE FROM net_pending_content WHERE serverID=? AND chatID=?",
            [.integer(try event.int("messageId")), .integer(chat)])
          if let row = try db.rows(
            "SELECT localID FROM net_messages WHERE serverID=?",
            [.integer(try event.int("messageId"))]
          ).first {
            let id = row["localID"]!.int
            try db.execute("UPDATE net_messages SET tombstone=1 WHERE localID=?", [.integer(id)])
            try db.execute("DELETE FROM messages WHERE id=?", [.integer(id)])
            removed[chat, default: []].append(id)
          }
        default: throw RepoError.corrupt
        }
      }
      guard try next == json.int("cursor") else { throw RepoError.corrupt }
      try state(db, "cursor", String(next))
      return try deltas(db, touched: touched, removed: removed, reason: .sync)
    }
  }

  // Принимает только сообщения нужного чата и сводит их с уже полученными событиями. Записывает
  // признак более старых страниц и возвращает изменения, которые можно показать без дублей.
  func history(_ db: SQLiteConnection, chat: Int64, data: Data) throws -> [MessageDelta] {
    let json = try WireObject(data: data)
    return try db.transaction {
      var ids: Set<Int64> = []
      for object in try json.array("messages") {
        let wire = try WireObject(object)
        guard try wire.int("chatId") == chat else { throw RepoError.corrupt }
        if let id = try merge(db, wire: wire) { ids.insert(id) }
      }
      try db.execute(
        "UPDATE net_chats SET hasOlder=? WHERE chatID=?",
        [.integer(try json.bool("hasOlder") ? 1 : 0), .integer(chat)])
      return try deltas(db, touched: [chat: ids], removed: [:], reason: .history)
    }
  }
}
