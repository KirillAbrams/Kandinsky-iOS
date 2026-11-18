// Сохраняет номера повтора и результаты действий с генерацией. Если сеть оборвётся раньше ответа,
// местная запись позволит снова послать ту же команду.

import Foundation

extension NetworkStore {
  // Сохраняет предложенный номер только если записи ещё нет, затем читает сохранённое значение.
  // Запуск приложения заново не заменит уже использованный номер повтора.
  func pendingRetry(_ db: SQLiteConnection, key: String, proposed: UUID?) throws -> String {
    let candidate = (proposed ?? UUID()).uuidString.lowercased()
    try db.execute(
      "INSERT OR IGNORE INTO net_state(key,value) VALUES(?,?)", [.text(key), .text(candidate)])
    guard
      let id = try db.rows("SELECT value FROM net_state WHERE key=?", [.text(key)]).first?["value"]?
        .string
    else { throw RepoError.corrupt }
    return id
  }

  // Проверяет принадлежность строк одному чату и сливает их в одной записи базы. Убирает отметку
  // повтора только для совпавшего номера, иначе старый ответ мог бы закрыть более новую попытку.
  func generationRows(
    _ db: SQLiteConnection, chat: Int64, data: Data,
    retryKey: String? = nil, operation: String? = nil
  ) throws -> [MessageDelta] {
    let json = try WireObject(data: data)
    return try db.transaction {
      var touched = Set<Int64>()
      for object in try json.array("messages") {
        let wire = try WireObject(object)
        guard try wire.int("chatId") == chat else { throw RepoError.corrupt }
        if let id = try merge(db, wire: wire) { touched.insert(id) }
      }
      if let retryKey, let operation {
        try db.execute(
          "DELETE FROM net_state WHERE key=? AND value=?", [.text(retryKey), .text(operation)])
      }
      return try deltas(db, touched: [chat: touched], removed: [:], reason: .sync)
    }
  }
}
