// Открываем отдельное хранилище для проверок, умеем повторно поднимать ту же папку и читать
// контрольные данные. Здесь же находим существующие чаты для проверок, которым нужна сеть.

import XCTest
import Foundation
import SQLite3
@testable import Kandinsky

final class RepositoryHarness {
  let root: URL
  let store: SQLiteStore
  let repo: SQLiteChatRepository
  let faults: RepositoryFaults
  // Связываем папку, открытую базу и управляемые ошибки. Строим обычное хранилище чатов поверх
  // этой же базы, чтобы проверки шли через рабочие операции.
  private init(root: URL, store: SQLiteStore, faults: RepositoryFaults) {
    self.root = root
    self.store = store
    self.faults = faults
    repo = SQLiteChatRepository(store: store)
  }
  // Открываем папку проверки или создаём новую, затем добавляем первый чат, если его нет. При
  // повторном открытии прежние записи и чат сохраняются.
  static func open(root: URL? = nil, faults: RepositoryFaults = RepositoryFaults()) async throws
    -> RepositoryHarness
  {
    let root =
      root
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "kandinsky-sql-" + UUID().uuidString)
    let store = try await SQLiteStore.open(root: root, faults: faults)
    let h = RepositoryHarness(root: root, store: store, faults: faults)
    try await store.perform { db in
      try db.execute(
        """
        INSERT OR IGNORE INTO chats(id,title,avatarKind,updatedSortKey,unreadCount,pinned) \
        VALUES(2,'Alica','initial',0,3,0)
        """
      )
    }
    return h
  }
  // Дожидаемся закрытия очереди хранилища. Это нужно перед повторным открытием и проверкой
  // переноса базы.
  func close() async throws { try await store.close() }
  // Закрываем базу и открываем ту же папку с теми же настройками ошибок. Так проверяем, что
  // состояние пережило закрытие соединения.
  func reopen() async throws -> RepositoryHarness {
    try await close()
    return try await Self.open(root: root, faults: faults)
  }
  // Сначала ждём окончания предыдущих действий в очереди, затем читаем число строк отдельным
  // соединением. Иначе счётчик мог бы опередить запись.
  func messageCount(chatID: ChatID) async throws -> Int {
    try await store.perform { _ in () }
    return try rawScalar("SELECT COUNT(*) FROM messages WHERE chatId=\(chatID)")
  }
  // Открываем местную базу только для чтения и берём первое целое число из запроса. После ответа
  // закрываем и подготовленную команду, и соединение.
  func rawScalar(_ sql: String) throws -> Int {
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        root.appendingPathComponent("chat.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil)
        == SQLITE_OK
    else { throw RepoError.io }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw RepoError.io }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw RepoError.io }
    return Int(sqlite3_column_int64(statement, 0))
  }
  // Запускаем встроенную проверку целостности через отдельное соединение без записи. Возвращаем
  // её ответ для сверки после нагрузки или переноса.
  func integrity() throws -> String {
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        root.appendingPathComponent("chat.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil)
        == SQLITE_OK
    else { throw RepoError.io }
    defer { sqlite3_close(db) }
    var s: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &s, nil) == SQLITE_OK else {
      throw RepoError.io
    }
    defer { sqlite3_finalize(s) }
    guard sqlite3_step(s) == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else {
      throw RepoError.io
    }
    return String(cString: text)
  }
  // Собираем старую схему в отдельной папке напрямую. Если взять текущий установщик, проверка
  // переноса начнётся с уже обновлённой базы.
  static func legacyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kandinsky-v1-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent("chat.sqlite3").path, &db) == SQLITE_OK else {
      throw RepoError.io
    }
    defer { sqlite3_close(db) }
    let sql =
      """
      CREATE TABLE chats(id INTEGER PRIMARY KEY,title TEXT NOT NULL,\
      avatarKind TEXT NOT NULL,lastMessageId INTEGER,updatedSortKey INTEGER NOT NULL,\
      unreadCount INTEGER NOT NULL,pinned INTEGER NOT NULL);\n\
      CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT,chatId INTEGER NOT NULL,\
      sortKey INTEGER NOT NULL,kind TEXT NOT NULL,text TEXT NOT NULL,caption TEXT NOT NULL,\
      replyToId INTEGER,revision INTEGER NOT NULL,savedAt INTEGER NOT NULL);\n\
      CREATE TABLE attachments(id TEXT PRIMARY KEY,messageId INTEGER NOT NULL,\
      relativePath TEXT NOT NULL,mime TEXT NOT NULL,byteSize INTEGER NOT NULL,\
      width INTEGER NOT NULL,height INTEGER NOT NULL,durationMs INTEGER,\
      thumbnailKey TEXT NOT NULL);\n\
      CREATE TABLE drafts(chatId INTEGER PRIMARY KEY,text TEXT NOT NULL,\
      attachmentDraft TEXT);\n\
      CREATE TABLE reading_positions(chatId INTEGER PRIMARY KEY,messageId INTEGER,\
      offsetWithin TEXT NOT NULL,followsBottom INTEGER NOT NULL,\
      layoutVersion INTEGER NOT NULL);\n\
      CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);\n\
      CREATE INDEX messages_chat_sort ON messages(chatId,sortKey,id);\n\
      CREATE INDEX attachments_message ON attachments(messageId);\n\
      INSERT INTO chats \
      VALUES(2,'Alica','initial',7,10,3,0);\n\
      INSERT INTO messages \
      VALUES(7,2,10,'text','Ранее 👋','',NULL,1,10);\n\
      INSERT INTO drafts \
      VALUES(2,'Старый черновик',NULL);\n\
      INSERT INTO metadata \
      VALUES('schema','1');\n\
      PRAGMA user_version=1;
      """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw RepoError.io }
    return root
  }
}

@MainActor enum StudioTestServer {
  // Читаем сохранённые настройки входа для сетевой проверки. Если аккаунт не открыт, пропускаем
  // сценарий вместо попытки зарегистрировать новый.
  static func profile() throws -> NetworkProfile {
    guard let profile = try NetworkCredentials.load() else {
      throw XCTSkip("Для проверки медиа нужен вход в существующий аккаунт приложения")
    }
    return profile
  }

  // Получаем список чатов и ищем точное название. Номер берём из ответа, поскольку он может
  // отличаться между аккаунтами.
  static func chat(_ title: String, api: NetworkAPI) async throws -> Int64 {
    let data = try await api.json("/v1/chats")
    let chats = try WireObject(data: data).array("chats").map { try WireObject($0) }
    return try XCTUnwrap(chats.first { (try? $0.string("title")) == title }).int("id")
  }

  // Находим «Плотную медиаленту» и читаем до 128 последних строк. Возвращаем номер чата вместе с
  // ответом для дальнейшей проверки вложений.
  static func recentMedia(_ api: NetworkAPI) async throws -> (Int64, Data) {
    let chat = try await chat("Плотная медиалента", api: api)
    let page = try await api.json("/v1/chats/\(chat)/history?limit=128")
    return (chat, page)
  }
}
