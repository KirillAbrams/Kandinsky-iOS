import Foundation
import CryptoKit
import SQLite3

typealias AttachmentLocationReader =
  @Sendable (SQLiteConnection, [MessageID]) throws -> [String: RemoteMediaLocation]

final class SQLiteChatRepository: ChatRepository, @unchecked Sendable {
  let store: SQLiteStore
  private let journal: LocalChangeJournal?
  init(store: SQLiteStore, journal: LocalChangeJournal? = nil) {
    self.store = store
    self.journal = journal
  }
  private static let columns =
    "id,chatId,sortKey,kind,text,caption,replyToId,revision,savedAt,direction,deliveryState"
  private static func preview(_ row: SQLRow) -> String {
    if row["lastId"]?.optionalInt == nil { return "Сообщений пока нет" }
    let text = row["lastText"]?.string ?? "", caption = row["lastCaption"]?.string ?? ""
    if row["lastKind"]?.string == "text" { return String(text.prefix(120)) }
    if !caption.isEmpty { return String(caption.prefix(120)) }
    return [
      "photo": "Фотография", "video": "Видео", "voice": "Голосовое сообщение",
      "round": "Видеокружочек", "gif": "GIF", "sticker": "Стикер"
    ][row["lastKind"]?.string ?? ""] ?? ""
  }
  private static func summaries(_ db: SQLiteConnection) throws -> [ChatSummary] {
    try db.rows(
      """
      SELECT c.*,m.id AS lastId,m.kind AS lastKind,m.text AS lastText,\
      m.caption AS lastCaption,m.savedAt AS lastSavedAt \
      FROM chats c \
      LEFT \
      JOIN messages m ON m.id=c.lastMessageId \
      ORDER BY c.pinned DESC,c.updatedSortKey DESC,c.id
      """
    ).map {
      ChatSummary(
        id: $0["id"]!.int, title: $0["title"]!.string, lastPreview: preview($0),
        lastSortKey: $0["updatedSortKey"]!.int, lastSavedAtMs: $0["lastSavedAt"]?.int ?? 0,
        unreadCount: Int($0["unreadCount"]!.int), pinned: $0["pinned"]!.int != 0)
    }
  }
  /// Если такого чата нет, возвращает ошибку отсутствующей записи, чтобы последующее действие не создало
  /// данные для чужого номера.
  static func summary(_ db: SQLiteConnection, _ id: ChatID) throws -> ChatSummary {
    guard let value = try summaries(db).first(where: { $0.id == id }) else {
      throw RepoError.notFound
    }
    return value
  }
  func markRead(chatID: ChatID) async throws {
    try await store.perform { [journal] db in
      try db.transaction {
        _ = try Self.summary(db, chatID)
        try db.execute("UPDATE chats SET unreadCount=0 WHERE id=?", [.integer(chatID)])
        try journal?.read(db, chatID: chatID)
      }
    }
  }
  func chats(matching query: String) async throws -> [ChatSummary] {
    try await store.perform { db in
      try Self.summaries(db).filter {
        query.isEmpty || $0.title.lowercased().contains(query.lowercased())
      }
    }
  }
  /// Сохраняет порядок вложений, чтобы результаты альбома не менялись местами после повторного открытия.
  static func messages(
    _ db: SQLiteConnection, _ rows: [SQLRow], locations: AttachmentLocationReader? = nil
  ) throws -> [Message] {
    guard !rows.isEmpty else { return [] }
    let ids = rows.map { $0["id"]!.int }
    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
    let attachments = try db.rows(
      """
      SELECT a.*,COALESCE(p.tinyPreview,c.tinyPreview) AS tinyPreview,COALESCE(p.waveform,\
      c.waveform) AS waveform \
      FROM attachments a \
      LEFT \
      JOIN media_previews p ON p.attachmentID=a.id \
      LEFT \
      JOIN media_preview_catalog c ON c.key=CASE WHEN a.relativePath LIKE 'seed/%' THEN \
      a.relativePath ELSE a.thumbnailKey END \
      WHERE messageId IN (
      """
        + placeholders + ") ORDER BY a.rowid", ids.map(SQLValue.integer))
    let remoteLocations: [String: RemoteMediaLocation]
    if let locations, !attachments.isEmpty {
      remoteLocations = try locations(db, ids)
    } else {
      remoteLocations = [:]
    }
    var grouped: [Int64: [Attachment]] = [:]
    for row in attachments {
      grouped[row["messageId"]!.int, default: []].append(
        Attachment(
          id: row["id"]!.string, relativePath: row["relativePath"]!.string,
          mime: row["mime"]!.string, byteSize: row["byteSize"]!.int,
          rawWidth: Int(row["width"]!.int), rawHeight: Int(row["height"]!.int),
          orientation: Int(row["orientation"]!.int), durationMs: row["durationMs"]?.optionalInt,
          thumbnailKey: row["thumbnailKey"]!.string,
          tinyPreview: MediaPreviewStorage.tiny(
            row["tinyPreview"].flatMap {
              if case let .text(s) = $0 { return s }
              return nil
            }), waveform: MediaPreviewStorage.readWave(row["waveform"]),
          remoteLocation: remoteLocations[row["id"]!.string]))
    }
    let generationIDs =
      locations == nil
      ? []
      : rows.filter {
        guard $0["direction"]?.string == "incoming" else { return false }
        if $0["kind"]?.string == "text" {
          return StudioGeneration.statusTexts.contains($0["text"]?.string ?? "")
        }
        return grouped[$0["id"]!.int]?.first?.id.contains("-result-") == true
      }.map { $0["id"]!.int }
    var generations: [Int64: StudioGeneration] = [:]
    if !generationIDs.isEmpty {
      let marks = generationIDs.map { _ in "?" }.joined(separator: ",")
      let metadata = try db.rows(
        "SELECT localID,payload FROM net_message_metadata WHERE localID IN (" + marks + ")",
        generationIDs.map(SQLValue.integer))
      let decoder = JSONDecoder()
      for row in metadata {
        if let payload = row["payload"]?.string,
          let value = try? decoder.decode(StudioGeneration.self, from: Data(payload.utf8))
        {
          let id = row["localID"]!.int
          if grouped[id]?.isEmpty != false || value.slots?.isEmpty == false {
            if value.stage != .succeeded || value.slots?.isEmpty == false {
              generations[id] = value
            }
          }
        }
      }
    }
    return try rows.map { row in
      guard let kind = MessageKind(rawValue: row["kind"]!.string),
        let direction = MessageDirection(rawValue: row["direction"]!.string),
        let delivery = MessageDelivery(rawValue: row["deliveryState"]!.string)
      else { throw RepoError.corrupt }
      let id = row["id"]!.int
      return Message(
        id: id, chatID: row["chatId"]!.int,
        order: OrderKey(sortKey: row["sortKey"]!.int, messageID: id), direction: direction,
        savedAtMs: row["savedAt"]!.int, kind: kind, text: row["text"]!.string,
        caption: row["caption"]!.string, replyToID: row["replyToId"]?.optionalInt,
        revision: Int(row["revision"]!.int), attachments: grouped[id] ?? [], delivery: delivery,
        studioGeneration: generations[id])
    }
  }
  private static func message(_ db: SQLiteConnection, _ id: MessageID) throws -> Message {
    guard
      let value = try messages(
        db, db.rows("SELECT " + columns + " FROM messages WHERE id=?", [.integer(id)])
      ).first
    else { throw RepoError.notFound }
    return value
  }
  /// Использует одновременно порядок сообщения и его номер, чтобы одинаковое время не приводило к
  /// пропуску на границе страницы.
  private static func range(_ anchor: OrderKey, older: Bool) -> (String, [SQLValue]) {
    let op = older ? "<" : ">"
    return (
      "(sortKey" + op + "? OR (sortKey=? AND id" + op + "?))",
      [.integer(anchor.sortKey), .integer(anchor.sortKey), .integer(anchor.messageID)]
    )
  }
  func history(_ request: PageRequest) async throws -> HistoryPage {
    try await history(request, locations: nil)
  }
  func history(_ request: PageRequest, locations: AttachmentLocationReader?) async throws
    -> HistoryPage
  {
    guard (1...128).contains(request.limit) else { throw RepoError.invalidInput }
    return try await store.perform { db in
      _ = try Self.summary(db, request.chatID)
      let visual = request.visualOnly ? " AND kind IN ('photo','video','gif')" : ""
      func query(_ anchor: OrderKey?, _ older: Bool, _ limit: Int) throws -> [SQLRow] {
        var sql = "SELECT " + Self.columns + " FROM messages WHERE chatId=?" + visual
        var values: [SQLValue] = [.integer(request.chatID)]
        if let anchor {
          let condition = Self.range(anchor, older: older)
          sql += " AND " + condition.0
          values += condition.1
        }
        sql +=
          " ORDER BY sortKey " + (older ? "DESC" : "ASC") + ",id " + (older ? "DESC" : "ASC")
          + " LIMIT ?"
        values.append(.integer(Int64(limit)))
        let result = try db.rows(sql, values)
        return older ? Array(result.reversed()) : result
      }
      let rows: [SQLRow]
      if request.direction == .around, let anchor = request.anchor {
        guard anchor.messageID < Int64.max else { throw RepoError.invalidInput }
        let older = try query(
          OrderKey(sortKey: anchor.sortKey, messageID: anchor.messageID + 1), true, request.limit)
        let newer = try query(anchor, false, request.limit)
        let before = min(older.count, max(request.limit / 2, request.limit - newer.count))
        rows = Array(older.suffix(before)) + Array(newer.prefix(request.limit - before))
      } else {
        rows = try query(request.anchor, request.direction != .newer, request.limit)
      }
      let items = try Self.messages(db, rows, locations: locations)
      func more(_ key: OrderKey?, _ older: Bool) throws -> OrderKey? {
        guard let key else { return nil }
        let condition = Self.range(key, older: older)
        let count = try db.scalar(
          "SELECT COUNT(*) FROM (SELECT 1 FROM messages WHERE chatId=?" + visual + " AND "
            + condition.0 + " LIMIT 1)", [.integer(request.chatID)] + condition.1)
        return count > 0 ? key : nil
      }
      return HistoryPage(
        rows: items, before: try more(items.first?.order, true),
        after: try more(items.last?.order, false))
    }
  }
  func index(chatID: ChatID) async throws -> [IndexedRow] {
    try await store.perform { db in
      _ = try Self.summary(db, chatID)
      var output: [IndexedRow] = []
      try db.forEachRow(
        """
        SELECT id,sortKey,savedAt AS savedAtMs,kind,revision,length(text) AS textLength \
        FROM messages \
        WHERE chatId=? \
        ORDER BY sortKey,id
        """,
        [.integer(chatID)]
      ) { row in
        let estimated =
          row["kind"]!.string == "text"
          ? min(360, max(44, 28 + ceil(Double(row["textLength"]!.int) / 32) * 21)) : 220
        output.append(
          IndexedRow(
            messageID: row["id"]!.int,
            order: OrderKey(sortKey: row["sortKey"]!.int, messageID: row["id"]!.int),
            estimatedHeight: estimated, revision: Int(row["revision"]!.int),
            savedAtMs: row["savedAtMs"]!.int))
        return true
      }
      return output
    }
  }
  private static func validate(_ c: SendCommand, _ root: URL) throws {
    guard !c.operationID.isEmpty, c.operationID.utf8.count <= 128, c.text.utf8.count <= 262144,
      c.caption.utf8.count <= 262144,
      !c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !c.attachments.isEmpty,
      c.kind == .text || !c.attachments.isEmpty
    else { throw RepoError.invalidInput }
    let media =
      root.appendingPathComponent("media").resolvingSymlinksInPath().standardizedFileURL.path + "/"
    for a in c.attachments {
      let parts = a.relativePath.split(separator: "/", omittingEmptySubsequences: false)
      guard !a.id.isEmpty, !a.relativePath.hasPrefix("/"), !parts.contains(".."),
        !parts.contains("."), !parts.contains(""), a.byteSize >= 0
      else { throw RepoError.invalidInput }
      let file = root.appendingPathComponent("media").appendingPathComponent(a.relativePath)
        .resolvingSymlinksInPath().standardizedFileURL
      guard file.path.hasPrefix(media), FileManager.default.fileExists(atPath: file.path) else {
        throw RepoError.invalidInput
      }
    }
  }
  /// В отпечаток входят данные отправки. Заново созданная миниатюра не должна превращать повтор в другой
  /// запрос.
  private static func payloadHash(_ c: SendCommand) throws -> String {
    let data = try JSONEncoder().encode(c)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object.removeValue(forKey: "operationID")
    if let attachments = object["attachments"] as? [[String: Any]] {
      object["attachments"] = attachments.map { value in
        var a = value
        a.removeValue(forKey: "tinyPreview")
        a.removeValue(forKey: "waveform")
        return a
      }
    }
    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
  }
  /// Ответ возвращает после подтверждения записи, поэтому потеря ответа не приводит к потере самого
  /// сообщения.
  func send(_ command: SendCommand) async throws -> MessageDelta {
    try await store.perform { [store, journal] db in
      try Self.validate(command, store.root)
      let hash = try Self.payloadHash(command)
      if let existing = try db.rows(
        "SELECT payloadHash,messageId FROM operations WHERE token=?", [.text(command.operationID)]
      ).first {
        guard existing["payloadHash"]!.string == hash else { throw RepoError.invalidInput }
        let message = try Self.message(db, existing["messageId"]!.int)
        return MessageDelta(inserted: [message], chat: try Self.summary(db, command.chatID))
      }
      if store.faults.consume(.storageFull) { throw SQLiteFailure(code: SQLITE_FULL) }
      let delta = try db.transaction {
        let previous = try Self.summary(db, command.chatID)
        if let reply = command.replyToID {
          guard try Self.message(db, reply).chatID == command.chatID else {
            throw RepoError.invalidInput
          }
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sort: Int64
        if journal != nil {
          // Неподтверждённые строки идут после серверной последовательности и упорядочены по местному номеру
          sort = Int64.max
        } else {
          guard previous.lastSortKey < Int64.max else { throw RepoError.invalidInput }
          sort = max(now, previous.lastSortKey + 1)
        }
        let id = try db.execute(
          """
          INSERT INTO messages(chatId,sortKey,kind,text,caption,replyToId,revision,savedAt,\
          direction,searchText) \
          VALUES(?,?,?,?,?,?,1,?,'outgoing',?)
          """,
          [
            .integer(command.chatID), .integer(sort), .text(command.kind.rawValue),
            .text(command.text), .text(command.caption),
            command.replyToID.map(SQLValue.integer) ?? .null, .integer(now),
            .text((command.text + " " + command.caption).lowercased())
          ])
        for a in command.attachments {
          try db.execute(
            """
            INSERT INTO attachments(id,messageId,relativePath,mime,byteSize,width,height,\
            durationMs,thumbnailKey,orientation) \
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """,
            [
              .text(a.id), .integer(id), .text(a.relativePath), .text(a.mime), .integer(a.byteSize),
              .integer(Int64(a.rawWidth)), .integer(Int64(a.rawHeight)),
              a.durationMs.map(SQLValue.integer) ?? .null, .text(a.thumbnailKey),
              .integer(Int64(a.orientation))
            ])
          try MediaPreviewStorage.save(db, id: a.id, tiny: a.tinyPreview, waveform: a.waveform)
        }
        try db.execute(
          "INSERT INTO operations(token,payloadHash,messageId) VALUES(?,?,?)",
          [.text(command.operationID), .text(hash), .integer(id)])
        try db.execute(
          "UPDATE chats SET lastMessageId=?,updatedSortKey=? WHERE id=?",
          [.integer(id), .integer(journal == nil ? sort : now), .integer(command.chatID)])
        try journal?.appended(db, command: command, localID: id)
        if store.faults.consume(.beforeCommit) { throw RepoError.io }
        return MessageDelta(
          inserted: [try Self.message(db, id)], chat: try Self.summary(db, command.chatID))
      }
      if store.faults.consume(.afterCommitBeforeReply) { throw RepoError.io }
      return delta
    }
  }
  func delete(messageID: MessageID) async throws -> MessageDelta {
    try await store.perform { [journal] db in
      try db.transaction {
        let message = try Self.message(db, messageID)
        try journal?.deleting(db, message: message)
        try db.execute("DELETE FROM messages WHERE id=?", [.integer(messageID)])
        let last = try db.rows(
          "SELECT id,sortKey,savedAt FROM messages WHERE chatId=? ORDER BY sortKey DESC,id DESC LIMIT 1",
          [.integer(message.chatID)]
        ).first
        let activity = last?[journal == nil ? "sortKey" : "savedAt"] ?? .integer(0)
        try db.execute(
          "UPDATE chats SET lastMessageId=?,updatedSortKey=? WHERE id=?",
          [last?["id"] ?? .null, activity, .integer(message.chatID)])
        return MessageDelta(removedIDs: [messageID], chat: try Self.summary(db, message.chatID))
      }
    }
  }
  func search(chatID: ChatID, text: String, before: OrderKey?) async throws -> [MessageID] {
    if text.isEmpty { return [] }
    return try await store.perform { db in
      _ = try Self.summary(db, chatID)
      var sql = "SELECT id FROM messages WHERE chatId=? AND instr(searchText,?)>0"
      var values: [SQLValue] = [.integer(chatID), .text(text.lowercased())]
      if let before {
        let condition = Self.range(before, older: true)
        sql += " AND " + condition.0
        values += condition.1
      }
      sql += " ORDER BY sortKey DESC,id DESC LIMIT 128"
      return try db.rows(sql, values).map { $0["id"]!.int }
    }
  }
  /// Отдельный состав незавершённой группы файлов сохраняет вместе с черновиком, чтобы восстановить его
  /// после перезапуска.
  func saveDraft(chatID: ChatID, draft: Draft) async throws {
    guard draft.text.utf8.count <= 262144, draft.revision >= 0 else { throw RepoError.invalidInput }
    let data = try JSONEncoder().encode(draft), json = String(decoding: data, as: UTF8.self)
    try await store.perform { db in
      _ = try Self.summary(db, chatID)
      try db.transaction {
        if let saved = try db.rows("SELECT revision FROM drafts WHERE chatId=?", [.integer(chatID)])
          .first, saved["revision"]!.int > draft.revision
        {
          return
        }
        try db.execute(
          "INSERT OR IGNORE INTO drafts(chatId,text,attachmentDraft,revision) VALUES(?,?,?,?)",
          [.integer(chatID), .text(draft.text), .text(json), .integer(draft.revision)])
        try db.execute(
          "UPDATE drafts SET text=?,attachmentDraft=?,revision=? WHERE chatId=? AND revision<=?",
          [
            .text(draft.text), .text(json), .integer(draft.revision), .integer(chatID),
            .integer(draft.revision)
          ])
        try MediaSelectionStorage.save(db, chatID: chatID, commands: draft.pendingMediaBatch)
        return ()
      }
    }
  }
  func draft(chatID: ChatID) async throws -> Draft {
    try await store.perform { db in
      let row = try db.rows(
        "SELECT text,attachmentDraft FROM drafts WHERE chatId=?", [.integer(chatID)]
      ).first
      var draft =
        row?["attachmentDraft"].flatMap {
          try? JSONDecoder().decode(Draft.self, from: Data($0.string.utf8))
        } ?? Draft(text: row?["text"]?.string ?? "")
      if let intent = try MediaSelectionStorage.load(db, chatID: chatID) {
        draft.pendingMediaBatch = intent
      }
      return draft
    }
  }
  func savePosition(chatID: ChatID, anchor: ReadingAnchor) async throws {
    guard anchor.fraction.isFinite, (0...1).contains(anchor.fraction), anchor.screenDelta.isFinite,
      abs(anchor.screenDelta) <= 8192, (anchor.textUTF16Offset ?? 0) >= 0, anchor.layoutVersion >= 1
    else { throw RepoError.invalidInput }
    let json = String(decoding: try JSONEncoder().encode(anchor), as: UTF8.self)
    try await store.perform { db in
      _ = try Self.summary(db, chatID)
      try db.execute(
        """
        INSERT OR REPLACE INTO reading_positions(chatId,messageId,offsetWithin,\
        followsBottom,layoutVersion) \
        VALUES(?,?,?,?,?)
        """,
        [
          .integer(chatID), anchor.messageID.map(SQLValue.integer) ?? .null, .text(json),
          .integer(anchor.followsBottom ? 1 : 0), .integer(Int64(anchor.layoutVersion))
        ])
    }
  }
  func position(chatID: ChatID) async throws -> ReadingAnchor? {
    try await store.perform { db in
      guard
        let row = try db.rows(
          "SELECT offsetWithin FROM reading_positions WHERE chatId=?", [.integer(chatID)]
        ).first
      else { return nil }
      guard
        let anchor = try? JSONDecoder().decode(
          ReadingAnchor.self, from: Data(row["offsetWithin"]!.string.utf8))
      else { throw RepoError.corrupt }
      return anchor
    }
  }
}
