import Foundation

extension NetworkStore {
  func mergeStudioDirectorySnapshot(
    _ db: SQLiteConnection, recent: Data, states: [Data] = [], startedAtCursor: Int64
  ) throws -> [MessageDelta] {
    let preserve = try cursor(db) != startedAtCursor
    var changes = try mergeChats(
      db, data: recent, studioRecent: true, preserveDirectoryMetadata: preserve)
    for page in states {
      changes += try mergeChats(db, data: page, preserveDirectoryMetadata: preserve)
    }
    return changes
  }

  private func studioArchive(_ db: SQLiteConnection, chat: Int64, archived: Bool) throws {
    var flags = try ChatServerState.state(db, chat: chat)
    guard (flags["archived"] as? Bool ?? false) != archived else { return }
    flags["archived"] = archived
    let bytes = try JSONSerialization.data(withJSONObject: flags)
    try db.execute(
      "INSERT OR REPLACE INTO net_chat_states VALUES(?,?)",
      [.integer(chat), .text(String(decoding: bytes, as: UTF8.self))])
  }

  // Скрываем старую историю на устройстве, чтобы задержавшаяся страница не вернула удалённый чат.
  func retireStudioThread(_ db: SQLiteConnection, chat: Int64) throws -> [Int64]? {
    guard try db.scalar("SELECT count(*) FROM chats WHERE id=?", [.integer(chat)]) > 0 else {
      return nil
    }
    var flags = try ChatServerState.state(db, chat: chat)
    guard flags["hidden"] as? Bool != true else { return nil }
    flags["id"] = chat
    flags["version"] = (flags["version"] as? NSNumber)?.int64Value ?? 0
    flags["clearThrough"] = Int64.max
    flags["hidden"] = true
    return try ChatServerState.applyState(db, chat: chat, value: flags)
  }

  // Старая сводка может прийти после новых сообщений. При обновлении счётчика учитываем сообщения за её границей.
  // Старые базы могут хранить границу уже прочитанной истории.
  private func legacyReadPosition(_ db: SQLiteConnection, chat: Int64) throws -> Int64 {
    let value =
      try db.rows("SELECT value FROM net_state WHERE key=?", [.text("ownRead:\(chat)")]).first?[
        "value"]?.string ?? "0"
    guard let through = Int64(value), through >= 0 else { throw RepoError.corrupt }
    return through
  }

  func mergeChatRows(
    _ db: SQLiteConnection, json: WireObject, touched: inout [Int64: Set<Int64>], limit: Int = 128,
    preserveDirectoryMetadata: Bool = false
  ) throws -> [Int64: [Int64]] {
    var removed: [Int64: [Int64]] = [:]
    let chats = try json.array("chats", limit: limit)
    for object in chats {
      let chat = try WireObject(object)
      let id = try chat.int("id")
      let title = try chat.string("title")
      let seq = try chat.int("lastSeq")
      let unread = try chat.int("unreadCount")
      if let state = chat.value["chatState"] as? [String: Any],
        let version = (state["version"] as? NSNumber)?.int64Value,
        version
          < ((try ChatServerState.state(db, chat: id)["version"] as? NSNumber)?.int64Value ?? -1)
      {
        continue
      }
      guard seq >= 0, unread >= 0 else {
        throw RepoError.corrupt
      }
      try db.execute(
        "INSERT OR IGNORE INTO chats(id,title) VALUES(?,?)", [.integer(id), .text(title)])
      try db.execute(
        "UPDATE chats SET title=?,pinned=? WHERE id=?",
        [.text(title), .integer(try chat.bool("pinned") ? 1 : 0), .integer(id)])
      let previouslyRead = try legacyReadPosition(db, chat: id)
      let later = try db.scalar(
        """
        SELECT count(*) \
        FROM net_messages n \
        JOIN messages m ON m.id=n.localID \
        WHERE m.chatId=? AND n.senderID<>? AND n.serverSeq>? AND n.serverSeq>?
        """,
        [.integer(id), .integer(userID), .integer(seq), .integer(previouslyRead)])
      guard unread <= Int64.max - later else { throw RepoError.corrupt }
      try db.execute(
        "UPDATE chats SET unreadCount=? WHERE id=?", [.integer(unread + later), .integer(id)])
      try db.execute(
        """
        INSERT INTO net_chats(chatID,lastSeq,hasOlder,title) \
        VALUES(?,?,1,?) \
        ON CONFLICT(chatID) \
        DO UPDATE \
        SET lastSeq=MAX(lastSeq,excluded.lastSeq),\
        title=excluded.title
        """,
        [
          .integer(id), .integer(seq),
          .text(title),
        ])
      let prior =
        Int64(
          try db.rows("SELECT value FROM net_state WHERE key=?", [.text("summarySeq:\(id)")])
            .first?["value"]?.string ?? "0") ?? 0
      try state(db, "summarySeq:\(id)", String(max(prior, seq)))
      touched[id] = []
      removed[id] = try ChatServerState.applyState(db, chat: id, value: chat.value["chatState"])
      if let archived = chat.value["archived"] as? Bool {
        try studioArchive(db, chat: id, archived: archived)
      }
      try rememberStudioDirectory(db, chat: chat, preserveKnown: preserveDirectoryMetadata)
      if let last = chat.value["lastMessage"] as? [String: Any],
        let local = try merge(db, wire: WireObject(last))
      {
        touched[id, default: []].insert(local)
      }
    }
    return removed
  }

  // Сводка не зависит от загруженной страницы сообщений и переживает закрытие приложения.
  func rememberStudioDirectory(
    _ db: SQLiteConnection, chat: WireObject, preserveKnown: Bool = false
  ) throws {
    guard chat.value["activityAtMs"] != nil else { return }
    let activity = try chat.int("activityAtMs")
    guard activity >= 0 else { throw RepoError.corrupt }
    let key = "studioDirectory:\(try chat.int("id"))"
    if preserveKnown, try db.scalar("SELECT count(*) FROM net_state WHERE key=?", [.text(key)]) > 0
    {
      return
    }
    let bytes = try JSONSerialization.data(
      withJSONObject: [
        "activityAtMs": activity, "generating": chat.value["generating"] as? Bool ?? false,
      ], options: .sortedKeys)
    try state(
      db, key, String(decoding: bytes, as: UTF8.self))
  }

  func mergeChats(
    _ db: SQLiteConnection, data: Data, studioRecent: Bool = false,
    preserveDirectoryMetadata: Bool = false
  ) throws
    -> [MessageDelta]
  {
    let json = try WireObject(data: data)
    return try db.transaction {
      var touched: [Int64: Set<Int64>] = [:]
      let removed = try mergeChatRows(
        db, json: json, touched: &touched,
        limit: studioRecent ? StudioRecentPage.catalogLimit : 128,
        preserveDirectoryMetadata: preserveDirectoryMetadata
      )
      if studioRecent { try rememberStudioRecent(db, json: json) }
      return try deltas(db, touched: touched, removed: removed, reason: .sync)
    }
  }

  func rememberStudioRecent(_ db: SQLiteConnection, json: WireObject) throws {
    let ids = try json.array("chats", limit: StudioRecentPage.catalogLimit).map {
      try WireObject($0).int("id")
    }
    let receivedAt = Int64(Date().timeIntervalSince1970 * 1000)
    try state(db, "studioRecentOrder", ([receivedAt] + ids).map(String.init).joined(separator: ","))
  }

  func studioChatIDs(_ db: SQLiteConnection) throws -> [Int64] {
    try db.rows("SELECT chatID FROM net_chats ORDER BY chatID").map { $0["chatID"]!.int }
  }

  func studioRecent(_ db: SQLiteConnection) throws -> StudioRecentPage {
    let saved = try db.rows("SELECT value FROM net_state WHERE key='studioRecentOrder'").first?[
      "value"]?.string
    let index = saved?.split(separator: ",").compactMap { Int64($0) } ?? []
    let refreshedAt = index.first ?? 0
    let order = Dictionary(
      index.dropFirst().enumerated().map { ($0.element, $0.offset) },
      uniquingKeysWith: { first, _ in first })
    let rows = try db.rows(
      """
      SELECT c.id,c.title,c.unreadCount,c.pinned,c.updatedSortKey,n.lastSeq,s.payload,d.value AS directory
      FROM chats c JOIN net_chats n ON n.chatID=c.id LEFT JOIN net_chat_states s ON s.chatID=c.id
      LEFT JOIN net_state d ON d.key='studioDirectory:' || c.id
      """
    ).compactMap { row -> (thread: StudioThread, activity: Int64, rank: Int)? in
      let flags =
        try row["payload"].flatMap { value -> [String: Any]? in
          guard case .text(let raw) = value else { return nil }
          return try WireObject(data: Data(raw.utf8)).value
        } ?? [:]
      guard !["archived", "hidden", "left"].contains(where: { flags[$0] as? Bool == true }) else {
        return nil
      }
      let id = row["id"]!.int
      let directory =
        try row["directory"].flatMap { value -> [String: Any]? in
          guard case .text(let raw) = value else { return nil }
          return try WireObject(data: Data(raw.utf8)).value
        } ?? [:]
      let activity =
        (directory["activityAtMs"] as? NSNumber)?.int64Value ?? row["updatedSortKey"]!.int
      let thread = StudioThread(
        id: id, title: row["title"]!.string, lastSeq: row["lastSeq"]!.int,
        unreadCount: row["unreadCount"]!.int, pinned: row["pinned"]!.int != 0, archived: false,
        activityAtMs: activity, generating: directory["generating"] as? Bool ?? false)
      return (thread, activity, activity > refreshedAt ? -1 : order[id] ?? Int.max)
    }.sorted { a, b in
      if a.thread.pinned != b.thread.pinned { return a.thread.pinned }
      if a.activity != b.activity { return a.activity > b.activity }
      if a.rank != b.rank { return a.rank < b.rank }
      return a.thread.id < b.thread.id
    }
    // Обычная серверная порция каталога содержит до двухсот чатов
    let catalogCount = index.dropFirst().count
    return StudioRecentPage(
      threads: rows.map(\.thread),
      nextOffset: catalogCount == StudioRecentPage.catalogLimit ? catalogCount : nil)
  }

  func hasUnknownChats(_ db: SQLiteConnection, data: Data) throws -> Bool {
    let packet = try WireObject(data: data)
    if packet.value["chats"] is [Any] { return false }
    let events = try packet.array("events")
    let ids = try Set(events.map { try WireObject($0).int("chatId") })
    guard !ids.isEmpty else { return false }
    let values = Array(ids)
    let marks = values.map { _ in "?" }.joined(separator: ",")
    return try db.rows(
      "SELECT id FROM chats WHERE id IN (" + marks + ")", values.map(SQLValue.integer)
    ).count != values.count
  }
}
