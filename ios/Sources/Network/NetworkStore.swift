// Хранит номер последнего события и собирает изменения местной ленты после записи. Экрану
// передаются только затронутые сообщения и сводка их чата.

import CoreFoundation
import Foundation

struct NetworkStore: Sendable {
  let userID: Int64
  // Читает последнюю сохранённую отметку обработки. Пока отметки нет, возвращает ноль, чтобы
  // первичная загрузка не пропустила историю.
  func cursor(_ db: SQLiteConnection) throws -> Int64 {
    Int64(
      try db.rows("SELECT value FROM net_state WHERE key='cursor'").first?["value"]?.string ?? "0")
      ?? 0
  }
  // Сравнивает сохранённую и подтверждённую отметки. Возвращает номер только если местная база
  // уже дошла дальше, иначе подтверждение повторилось бы без причины.
  func cursorAwaitingConfirmation(_ db: SQLiteConnection) throws -> Int64? {
    let saved = try cursor(db)
    let confirmed = try db.scalar(
      "SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM net_state WHERE key='ackedCursor'), -1)")
    return saved > confirmed ? saved : nil
  }

  // Проверяет наличие записи отметки. Наличие и значение различаются, потому что ноль может быть
  // сохранённым начальным состоянием.
  func initialized(_ db: SQLiteConnection) throws -> Bool {
    try !db.rows("SELECT 1 FROM net_state WHERE key='cursor'").isEmpty
  }
  // Записывает новое значение под тем же служебным ключом. Следующее чтение получает одну
  // актуальную запись вместо нескольких версий.
  func state(_ db: SQLiteConnection, _ key: String, _ value: String) throws {
    try db.execute(
      "INSERT OR REPLACE INTO net_state(key,value) VALUES(?,?)", [.text(key), .text(value)])
  }
  // Пересчитывает последнее сообщение каждого затронутого чата, читает изменённые строки и
  // прикладывает номера удалений. Экран получает готовое обновление без полного перечитывания
  // истории.
  func deltas(
    _ db: SQLiteConnection, touched: [Int64: Set<Int64>], removed: [Int64: [Int64]],
    reason: MessageChangeReason
  ) throws -> [MessageDelta] {
    try touched.map { chat, ids in
      try db.execute(
        """
        UPDATE chats \
        SET lastMessageId=(SELECT id \
        FROM messages \
        WHERE chatId=? \
        ORDER BY sortKey DESC,id DESC LIMIT 1),updatedSortKey=COALESCE((SELECT savedAt \
        FROM messages \
        WHERE chatId=? \
        ORDER BY sortKey DESC,id DESC LIMIT 1),0) \
        WHERE id=?
        """,
        [.integer(chat), .integer(chat), .integer(chat)])
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
      let messages =
        ids.isEmpty
        ? []
        : try SQLiteChatRepository.messages(
          db,
          db.rows(
            "SELECT * FROM messages WHERE id IN (" + placeholders + ")", ids.map(SQLValue.integer)),
          locations: { db, ids in try Self.attachmentLocations(db, ids) })
      return MessageDelta(
        updated: messages, removedIDs: removed[chat] ?? [],
        chat: try ChatServerState.decorate(db, SQLiteChatRepository.summary(db, chat)),
        reason: reason)
    }
  }
}
