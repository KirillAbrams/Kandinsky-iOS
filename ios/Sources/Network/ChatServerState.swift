// Хранит на телефоне полученное с сервера состояние чата. Отметки об удалении нужны, чтобы
// запоздалое сообщение не попало обратно в ленту.

import Foundation

enum ChatServerState {
  // Дополняет строку списка сведениями об архиве, звуке и отметке о прочтении. Скрытый или
  // покинутый чат помечает скрытым, иначе список показывал бы его как обычный.
  static func decorate(_ db: SQLiteConnection, _ summary: ChatSummary) throws -> ChatSummary {
    let value = try state(db, chat: summary.id)
    var result = summary
    result.archived = value["archived"] as? Bool ?? false
    result.muted = value["muted"] as? Bool ?? false
    result.markedUnread = value["markedUnread"] as? Bool ?? false
    result.hidden = value["hidden"] as? Bool == true || value["left"] as? Bool == true
    return result
  }
  // Читает последнее сохранённое описание чата по его номеру. Если сведений ещё нет, возвращает
  // пустое описание, чтобы список мог показаться до обмена с сервером.
  static func state(_ db: SQLiteConnection, chat: Int64) throws -> [String: Any] {
    guard
      let raw = try db.rows("SELECT payload FROM net_chat_states WHERE chatID=?", [.integer(chat)])
        .first?["payload"]?.string
    else { return [:] }
    return try WireObject(data: Data(raw.utf8)).value
  }

  // Проверяет номер чата, размер и версию ответа. Сохраняет наибольшую границу очистки, помечает
  // старые сообщения удалёнными, убирает их из ленты и обновляет закрепление и счётчик.
  // Возвращает номера снятых строк, чтобы вызывающий код обновил экран.
  static func applyState(_ db: SQLiteConnection, chat: Int64, value: Any?) throws -> [Int64] {
    guard let value, !(value is NSNull) else { return [] }
    let wire = try WireObject(value), version = try wire.int("version"),
      cutoff = try wire.int("clearThrough")
    guard try wire.int("id") == chat, version >= 0, cutoff >= 0 else { throw RepoError.corrupt }
    let old = try state(db, chat: chat)
    if version < (old["version"] as? NSNumber)?.int64Value ?? -1 { return [] }
    var next = wire.value
    let through = max(cutoff, (old["clearThrough"] as? NSNumber)?.int64Value ?? 0)
    next["clearThrough"] = through
    let data = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
    guard data.count <= 16384 else { throw RepoError.corrupt }
    try db.execute(
      "INSERT OR REPLACE INTO net_chat_states(chatID,payload) VALUES(?,?)",
      [.integer(chat), .text(String(decoding: data, as: UTF8.self))])
    let ids = try db.rows(
      """
      SELECT m.id \
      FROM messages m \
      JOIN net_messages n ON n.localID=m.id \
      WHERE m.chatId=? AND n.serverSeq>0 AND n.serverSeq<=?
      """,
      [.integer(chat), .integer(through)]
    ).map { $0["id"]!.int }
    try db.execute(
      """
      INSERT OR IGNORE INTO net_tombstones SELECT n.serverID,? \
      FROM net_messages n \
      JOIN messages m ON m.id=n.localID \
      WHERE m.chatId=? AND n.serverID IS NOT NULL AND n.serverSeq<=?
      """,
      [.integer(chat), .integer(chat), .integer(through)])
    try db.execute(
      "UPDATE net_messages SET tombstone=1 WHERE serverID IN (SELECT serverID FROM net_tombstones WHERE chatID=?)",
      [.integer(chat)])
    try db.execute(
      "DELETE FROM net_pending_content WHERE chatID=? AND serverID IN (SELECT serverID FROM net_tombstones)",
      [.integer(chat)])
    try db.execute(
      "DELETE FROM messages WHERE chatId=? AND id IN (SELECT localID FROM net_messages WHERE tombstone=1)",
      [.integer(chat)])
    try db.execute(
      "UPDATE chats SET pinned=?,unreadCount=? WHERE id=?",
      [
        .integer(
          wire.value["kind"] as? String == "saved" || (wire.optionalInt("pinnedAtMs") ?? 0) > 0
            ? 1 : 0), .integer(max(0, wire.optionalInt("unreadCount") ?? 0)), .integer(chat)
      ])
    return ids
  }

  // Проверяет отметку об удалении сообщения и границу очистки чата. Если сообщение подходит хотя
  // бы под одно условие, поздняя доставка его уже не вернёт.
  static func isHidden(_ db: SQLiteConnection, server: Int64, chat: Int64, seq: Int64) throws
    -> Bool
  {
    if try db.scalar("SELECT count(*) FROM net_tombstones WHERE serverID=?", [.integer(server)]) > 0
    {
      return true
    }
    return seq <= ((try state(db, chat: chat)["clearThrough"] as? NSNumber)?.int64Value ?? 0)
  }
}
