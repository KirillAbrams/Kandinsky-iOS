// Сводит серверное сообщение с местной отправкой и сохраняет связи вложений. Подтверждение сети
// обновляет уже существующую строку, чтобы в ленте не было дублей.

import Foundation

extension NetworkStore {
  // Ищет запись по номеру сервера или исходной отправки, пропускает удалённые и устаревшие
  // версии. Обновляет текст, сведения и вложения, оставляет путь своего файла при совпадении
  // содержимого. Для принятой отправки убирает команду повтора.
  func merge(_ db: SQLiteConnection, wire: WireObject) throws -> Int64? {
    let server = try wire.int("id")
    let chat = try wire.int("chatId")
    let sender = try wire.int("senderId")
    if try ChatServerState.isHidden(db, server: server, chat: chat, seq: wire.int("seq")) {
      return nil
    }
    let client = try wire.string("clientId").lowercased()
    let revision = try wire.int("revision")
    let mapping = try db.rows(
      "SELECT localID,remoteRevision,tombstone FROM net_messages WHERE serverID=? OR (clientID=? AND senderID=?)",
      [.integer(server), .text(client), .integer(sender)]
    ).first
    if let mapping, mapping["tombstone"]!.int != 0 || mapping["remoteRevision"]!.int >= revision {
      return nil
    }
    let kind = try wire.string("kind")
    guard MessageKind(rawValue: kind) != nil else { throw RepoError.corrupt }
    let own = sender == userID
    // Путь принятой собственной загрузки можно сохранить только при неизменном серверном файле
    let oldAttachments =
      try (mapping != nil && own)
      ? db.rows(
        """
        SELECT a.relativePath,COALESCE(m.blobID,u.blobID) AS blobID \
        FROM attachments a \
        LEFT \
        JOIN net_media m ON m.attachmentID=a.id \
        LEFT \
        JOIN net_uploads u ON u.attachmentID=a.id \
        WHERE a.messageId=? \
        ORDER BY a.rowid
        """,
        [mapping!["localID"]!]) : []
    var reply: SQLValue = .null
    if let replyID = wire.optionalInt("replyToId") {
      reply =
        try db.rows("SELECT localID FROM net_messages WHERE serverID=?", [.integer(replyID)])
        .first?["localID"] ?? .null
    }
    let text = try wire.string("text")
    let caption = try wire.string("caption")
    let seq = try wire.int("seq")
    let values: [SQLValue] = [
      .integer(chat), .integer(seq), .integer(try wire.int("savedAtMs")), .text(kind), .text(text),
      .text(caption), .text(own ? "outgoing" : "incoming"),
      .text((text + " " + caption).lowercased()), reply
    ]
    let id: Int64
    if let mapping {
      id = mapping["localID"]!.int
      try db.execute(
        """
        UPDATE messages \
        SET chatId=?,sortKey=?,savedAt=?,kind=?,text=?,caption=?,direction=?,searchText=?,\
        replyToId=?,revision=revision+1,deliveryState=CASE WHEN direction='outgoing' AND \
        deliveryState IN ('pending','failed') THEN 'accepted' ELSE deliveryState END \
        WHERE id=?
        """,
        values + [.integer(id)])
    } else {
      id = try db.execute(
        """
        INSERT INTO messages(chatId,sortKey,savedAt,kind,text,caption,direction,searchText,\
        replyToId,revision,deliveryState) \
        VALUES(?,?,?,?,?,?,?,?,?,1,?)
        """,
        values + [.text(own ? "accepted" : "local")])
    }
    try db.execute(
      """
      INSERT OR REPLACE INTO net_messages(localID,serverID,clientID,senderID,serverSeq,\
      remoteRevision,tombstone) \
      VALUES(?,?,?,?,?,?,0)
      """,
      [
        .integer(id), .integer(server), .text(client), .integer(sender), .integer(seq),
        .integer(revision)
      ])
    let metadata = try JSONSerialization.data(
      withJSONObject: wire.value["metadata"] as? [String: Any] ?? [:], options: [.sortedKeys])
    try db.execute(
      "INSERT OR REPLACE INTO net_message_metadata VALUES(?,?)",
      [.integer(id), .text(String(decoding: metadata, as: UTF8.self))])
    try db.execute("DELETE FROM attachments WHERE messageId=?", [.integer(id)])
    let attachments = try wire.array("attachments")
    guard attachments.count <= 10 else { throw RepoError.corrupt }
    for (i, object) in attachments.enumerated() {
      let attachment = try WireObject(object)
      let blob = try attachment.string("blobId")
      guard [32, 64].contains(blob.count), blob.allSatisfy({ "0123456789abcdef".contains($0) })
      else { throw RepoError.corrupt }
      let attachmentID =
        attachment.optionalString("resultJobId") != nil
        ? "net-\(server)-result-\(blob)" : "net-\(server)-\(i)"
      let cached = i < oldAttachments.count ? oldAttachments[i] : nil
      let path =
        cached?["blobID"]?.string == blob
        ? cached!["relativePath"]!.string
        : NetworkMedia.relativePath(blob: blob, mime: try attachment.string("mime"))
      try db.execute(
        """
        INSERT INTO attachments(id,messageId,relativePath,mime,byteSize,width,height,\
        durationMs,thumbnailKey,orientation) \
        VALUES(?,?,?,?,?,?,?,?,?,?)
        """,
        [
          .text(attachmentID), .integer(id), .text(path), .text(try attachment.string("mime")),
          .integer(try attachment.int("byteSize")), .integer(try attachment.int("rawWidth")),
          .integer(try attachment.int("rawHeight")),
          attachment.optionalInt("durationMs").map(SQLValue.integer) ?? .null, .text(blob),
          .integer(try attachment.int("orientation"))
        ])
      try MediaPreviewStorage.save(
        db, id: attachmentID, tiny: attachment.optionalString("tinyPreview"),
        waveform: (attachment.value["waveform"] as? [Int]).flatMap { values in
          guard values.count <= 128, values.allSatisfy({ (0...255).contains($0) }) else {
            return nil
          }
          return values.map(UInt8.init)
        })
      try db.execute(
        "INSERT OR REPLACE INTO net_media(attachmentID,blobID,previewBlobID,mime,byteSize) VALUES(?,?,?,?,?)",
        [
          .text(attachmentID), .text(blob),
          attachment.optionalString("previewBlobId").map(SQLValue.text) ?? .null,
          .text(try attachment.string("mime")), .integer(try attachment.int("byteSize"))
        ])
    }
    try db.execute(
      "UPDATE net_chats SET lastSeq=MAX(lastSeq,?) WHERE chatID=?", [.integer(seq), .integer(chat)])
    if own {
      try db.execute("DELETE FROM net_outbox WHERE id=? AND action='send'", [.text(client)])
    }
    return id
  }

  // Читает места медиа по списку сообщений порциями по сто двадцать восемь. Так большой набор
  // изменений не превращается в один запрос с чрезмерным числом параметров.
  static func attachmentLocations(_ db: SQLiteConnection, _ messageIDs: [MessageID]) throws
    -> [String: RemoteMediaLocation]
  {
    var result: [String: RemoteMediaLocation] = [:]
    // На странице истории не больше ста двадцати восьми сообщений, но изменения просмотров могут быть
    // крупнее.
    for start in stride(from: 0, to: messageIDs.count, by: 128) {
      let ids = Array(messageIDs[start..<min(start + 128, messageIDs.count)])
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
      let rows = try db.rows(
        "SELECT r.* FROM net_media r JOIN attachments a ON a.id=r.attachmentID WHERE a.messageId IN ("
          + placeholders + ")", ids.map(SQLValue.integer))
      for row in rows {
        let preview = row["previewBlobID"].flatMap { value -> String? in
          if case .text(let s) = value { return s }
          return nil
        }
        result[row["attachmentID"]!.string] = RemoteMediaLocation(
          blobID: row["blobID"]!.string, previewBlobID: preview, mime: row["mime"]!.string,
          byteSize: row["byteSize"]!.int)
      }
    }
    return result
  }
}
