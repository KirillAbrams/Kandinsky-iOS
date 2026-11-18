import Foundation

enum NetworkSchema {
  static func install(_ database: SQLiteConnection) throws {
    try database.transaction {
      for statement in statements { try database.execute(statement) }
      let version = try database.rows("SELECT value FROM net_state WHERE key='schema'").first?[
        "value"]?.string
      guard version == nil || version == "1" else { throw RepoError.corrupt }
      try database.execute("INSERT OR IGNORE INTO net_state(key,value) VALUES('schema','1')")
      try repairQueuedOrder(database)
    }
  }

  /// Переносит их к общей границе ожидающих отправок и повышает версию, чтобы сцена пересчитала
  /// изменившиеся строки.
  private static func repairQueuedOrder(_ database: SQLiteConnection) throws {
    let legacyRows = """
      FROM net_outbox o JOIN net_messages n ON n.localID=o.localID
      JOIN messages m ON m.id=o.localID
      WHERE o.action='send' AND n.serverID IS NULL AND n.tombstone=0 AND m.sortKey<>?
      """
    let pendingOrder = SQLValue.integer(Int64.max)
    let chats = try database.rows("SELECT DISTINCT m.chatId " + legacyRows, [pendingOrder])
    guard !chats.isEmpty else { return }
    try database.execute(
      "UPDATE messages SET sortKey=?,revision=revision+1 WHERE id IN (SELECT m.id " + legacyRows
        + ")", [pendingOrder, pendingOrder])
    for row in chats {
      let chat = row["chatId"]!
      let tail = try database.rows(
        "SELECT id,savedAt FROM messages WHERE chatId=? ORDER BY sortKey DESC,id DESC LIMIT 1",
        [chat]
      ).first
      try database.execute(
        "UPDATE chats SET lastMessageId=?,updatedSortKey=? WHERE id=?",
        [tail?["id"] ?? .null, tail?["savedAt"] ?? .integer(0), chat])
    }
  }

  private static let statements = [
    "CREATE TABLE IF NOT EXISTS net_message_metadata(localID INTEGER PRIMARY KEY,payload TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS net_tombstones(serverID INTEGER PRIMARY KEY,chatID INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS net_chat_states(chatID INTEGER PRIMARY KEY,payload TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS net_pending_receipts(serverID INTEGER PRIMARY KEY)",
    """
    CREATE TABLE IF NOT EXISTS net_pending_content(serverID INTEGER PRIMARY KEY,\
    chatID INTEGER NOT NULL,errorCode TEXT)
    """,
    """
    CREATE INDEX IF NOT EXISTS net_pending_content_ready ON net_pending_content(chatID,\
    serverID) \
    WHERE errorCode IS NULL
    """,
    """
    CREATE TABLE IF NOT EXISTS net_content_receipts(serverID INTEGER NOT NULL,\
    userID INTEGER NOT NULL,chatID INTEGER NOT NULL,PRIMARY KEY(serverID,userID))
    """,
    "CREATE TABLE IF NOT EXISTS net_state(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
    """
    CREATE TABLE IF NOT EXISTS net_chats(chatID INTEGER PRIMARY KEY,\
    lastSeq INTEGER NOT NULL DEFAULT 0,hasOlder INTEGER NOT NULL DEFAULT 1,\
    peerUserID INTEGER,title TEXT NOT NULL)
    """,
    // Сохраняем соответствия после местного удаления, чтобы повтор не вернул скрытое сообщение
    """
    CREATE TABLE IF NOT EXISTS net_messages(localID INTEGER PRIMARY KEY,\
    serverID INTEGER UNIQUE,clientID TEXT NOT NULL,senderID INTEGER NOT NULL,\
    serverSeq INTEGER NOT NULL DEFAULT 0,remoteRevision INTEGER NOT NULL DEFAULT 0,\
    tombstone INTEGER NOT NULL DEFAULT 0,UNIQUE(senderID,clientID))
    """,
    """
    CREATE TABLE IF NOT EXISTS net_outbox(id TEXT PRIMARY KEY,action TEXT NOT NULL,\
    localID INTEGER,payload TEXT NOT NULL,payloadBytes INTEGER NOT NULL,\
    mediaBytes INTEGER NOT NULL DEFAULT 0,errorCode TEXT)
    """,
    """
    CREATE TABLE IF NOT EXISTS net_reads(chatID INTEGER PRIMARY KEY,\
    through INTEGER NOT NULL,sentThrough INTEGER NOT NULL DEFAULT 0)
    """,
    """
    CREATE TABLE IF NOT EXISTS net_media(attachmentID TEXT PRIMARY KEY,blobID TEXT NOT NULL,\
    previewBlobID TEXT,mime TEXT NOT NULL,byteSize INTEGER NOT NULL)
    """,
    "CREATE TABLE IF NOT EXISTS net_uploads(attachmentID TEXT PRIMARY KEY,blobID TEXT NOT NULL,previewBlobID TEXT)"
  ]
}
