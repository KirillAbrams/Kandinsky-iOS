import Foundation

struct NetworkJournal: LocalChangeJournal {
  let userID: Int64

  // Старые команды мессенджера могут остаться после обновления. Они не должны задерживать запросы генерации.
  static func readyOperations(_ database: SQLiteConnection) throws -> [SQLRow] {
    try database.rows(
      """
      SELECT id,action,payload \
      FROM net_outbox \
      WHERE errorCode IS NULL AND action IN ('send','delete') \
      ORDER BY rowid LIMIT 32
      """,
      maxBytes: 48 * 1024)
  }

  // Записываем сообщение и номер операции до отправки. При потере ответа телефон сможет повторить ту же команду.
  func appended(_ database: SQLiteConnection, command: SendCommand, localID: MessageID) throws {
    guard let operation = UUID(uuidString: command.operationID), command.text.utf8.count <= 16384,
      command.caption.utf8.count <= 4096, command.attachments.count <= 10,
      command.attachments.allSatisfy({ (1...67_108_864).contains($0.byteSize) })
    else { throw RepoError.invalidInput }
    let data = try JSONEncoder().encode(command)
    guard data.count <= 40960, let payload = String(data: data, encoding: .utf8) else {
      throw RepoError.invalidInput
    }
    let mediaBytes = command.attachments.reduce(Int64(0)) { $0 + $1.byteSize }
    try reserve(database, bytes: data.count, mediaBytes: mediaBytes)
    let id = operation.uuidString.lowercased()
    try database.execute(
      "INSERT INTO net_messages(localID,clientID,senderID) VALUES(?,?,?)",
      [.integer(localID), .text(id), .integer(userID)])
    try database.execute(
      "INSERT INTO net_outbox(id,action,localID,payload,payloadBytes,mediaBytes) VALUES(?,'send',?,?,?,?)",
      [
        .text(id), .integer(localID), .text(payload), .integer(Int64(data.count)),
        .integer(mediaBytes)
      ])
    try database.execute(
      "UPDATE messages SET deliveryState='pending' WHERE id=?", [.integer(localID)])
  }

  // Если сервер окончательно отклонил отправку, у него ещё нет сообщения, которое нужно удалять.
  func deleting(_ database: SQLiteConnection, message: Message) throws {
    guard
      let mapping = try database.rows(
        "SELECT serverID,clientID,senderID FROM net_messages WHERE localID=?",
        [.integer(message.id)]
      ).first
    else { return }
    try database.execute(
      "UPDATE net_messages SET tombstone=1 WHERE localID=?", [.integer(message.id)])
    guard mapping["senderID"]?.int == userID else { return }
    let rejected = try !database.rows(
      "SELECT 1 FROM net_outbox WHERE action='send' AND localID=? AND errorCode IS NOT NULL",
      [.integer(message.id)]
    ).isEmpty
    if mapping["serverID"]?.optionalInt == nil, rejected {
      try database.execute("DELETE FROM net_outbox WHERE localID=?", [.integer(message.id)])
      return
    }
    let object: [String: Any] = [
      "chatId": message.chatID, "messageId": mapping["serverID"]?.optionalInt as Any? ?? NSNull(),
      "targetClientId": mapping["clientID"]?.string ?? ""
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let payload = String(data: data, encoding: .utf8) else { throw RepoError.corrupt }
    try reserve(database, bytes: data.count, mediaBytes: 0)
    try database.execute(
      "INSERT INTO net_outbox(id,action,localID,payload,payloadBytes) VALUES(?,'delete',?,?,?)",
      [
        .text(UUID().uuidString.lowercased()), .integer(message.id), .text(payload),
        .integer(Int64(data.count))
      ])
  }

  // Для чата достаточно последней границы чтения. Новое значение заменяет предыдущую команду в очереди.
  func read(_ database: SQLiteConnection, chatID: ChatID) throws {
    guard
      let row = try database.rows(
        "SELECT lastSeq FROM net_chats WHERE chatID=?", [.integer(chatID)]
      ).first
    else { return }
    let through = row["lastSeq"]?.int ?? 0
    try database.execute(
      "INSERT OR IGNORE INTO net_reads(chatID,through) VALUES(?,?)",
      [.integer(chatID), .integer(through)])
    try database.execute(
      "UPDATE net_reads SET through=MAX(through,?) WHERE chatID=?",
      [.integer(through), .integer(chatID)])
  }

  // Учитываем ожидающие отправки и их файлы, чтобы очередь не заняла всё место на телефоне.
  private func reserve(_ database: SQLiteConnection, bytes: Int, mediaBytes: Int64) throws {
    guard
      let budget = try database.rows(
        """
        SELECT count(*) AS n,COALESCE(sum(payloadBytes),0) AS payload,\
        COALESCE(sum(mediaBytes),0) AS media \
        FROM net_outbox \
        WHERE action IN ('send','delete')
        """
      ).first,
      budget["n"]!.int < 256, budget["payload"]!.int + Int64(bytes) <= 2 * 1024 * 1024,
      budget["media"]!.int + mediaBytes <= 512 * 1024 * 1024
    else { throw RepoError.storageFull }
  }
}
