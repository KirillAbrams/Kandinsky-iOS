// Записывает принятие и окончательный отказ отправленных команд в местную базу. Сетевой номер
// связывается с прежней строкой, чтобы на экране не появлялся дубликат.

import Foundation

extension NetworkStore {
  // Находит своё сообщение по номеру операции и записывает номер сервера, порядок, время и
  // состояние принятия. Убирает подтверждённую команду в той же записи, иначе после обрыва
  // пришлось бы повторять её вхолостую.
  func accepted(_ db: SQLiteConnection, data: Data) throws -> [MessageDelta] {
    let json = try WireObject(data: data)
    return try db.transaction {
      var touched: [Int64: Set<Int64>] = [:]
      for object in try json.array("messages") {
        let row = try WireObject(object)
        let client = try row.string("clientId").lowercased()
        if let mapping = try db.rows(
          """
          SELECT n.localID,m.chatId \
          FROM net_messages n \
          LEFT \
          JOIN messages m ON m.id=n.localID \
          WHERE n.clientID=? AND n.senderID=?
          """,
          [.text(client), .integer(userID)]
        ).first {
          let id = mapping["localID"]!.int
          try db.execute(
            "UPDATE net_messages SET serverID=?,serverSeq=? WHERE localID=?",
            [.integer(try row.int("id")), .integer(try row.int("seq")), .integer(id)])
          try db.execute(
            """
            UPDATE messages \
            SET sortKey=?,savedAt=?,revision=revision+1,\
            deliveryState=CASE WHEN deliveryState IN ('pending',\
            'failed') THEN 'accepted' ELSE deliveryState END \
            WHERE id=?
            """,
            [.integer(try row.int("seq")), .integer(try row.int("savedAtMs")), .integer(id)])
          if let chat = mapping["chatId"]?.optionalInt { touched[chat, default: []].insert(id) }
        }
        try db.execute("DELETE FROM net_outbox WHERE id=? AND action='send'", [.text(client)])
      }
      return try deltas(db, touched: touched, removed: [:], reason: .sync)
    }
  }

  // Сохраняет код отказа в очереди и повышает версию затронутых сообщений, чтобы экран увидел
  // ошибку. Убирает связанные команды удаления, когда нет принятой отправки, которую они могли бы
  // удалить.
  func failed(_ db: SQLiteConnection, ids: [String], code: String) throws -> [MessageDelta] {
    guard !ids.isEmpty, ids.count <= 32 else { return [] }
    return try db.transaction {
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
      let values = ids.map(SQLValue.text)
      var touched: [ChatID: Set<MessageID>] = [:]
      for row in try db.rows(
        "SELECT m.id,m.chatId FROM messages m JOIN net_outbox o ON o.localID=m.id WHERE o.id IN ("
          + placeholders + ")", values)
      { touched[row["chatId"]!.int, default: []].insert(row["id"]!.int) }
      try db.execute(
        "UPDATE net_outbox SET errorCode=? WHERE id IN (" + placeholders + ")",
        [.text(code)] + values)
      try db.execute(
        """
        UPDATE messages \
        SET deliveryState='failed',revision=revision+1 \
        WHERE id IN (SELECT localID \
        FROM net_outbox \
        WHERE id IN (
        """
          + placeholders + "))", values)
      try db.execute(
        "DELETE FROM net_outbox WHERE action='delete' AND localID IN (SELECT localID FROM net_outbox WHERE id IN ("
          + placeholders + "))", values)
      return try deltas(db, touched: touched, removed: [:], reason: .sync)
    }
  }
}
