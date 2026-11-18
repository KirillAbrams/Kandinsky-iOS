import Foundation

enum MediaSelectionStorage {
  static let maximumPayloadBytes = 1_048_576
  static func install(_ db: SQLiteConnection) throws {
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS media_selection_intents(chatID INTEGER PRIMARY KEY \
      REFERENCES chats(id) ON DELETE CASCADE,payload TEXT NOT NULL)
      """
    )
  }
  private static func valid(_ commands: [SendCommand], chatID: ChatID) -> Bool {
    guard chatID > 0, (1...32).contains(commands.count),
      commands.reduce(0, { $0 + $1.attachments.count }) <= 32,
      Set(commands.map { $0.operationID.lowercased() }).count == commands.count
    else { return false }
    return commands.allSatisfy { command in
      command.chatID == chatID && UUID(uuidString: command.operationID) != nil
        && (1...10).contains(command.attachments.count)
        && command.attachments.allSatisfy { attachment in
          let parts = attachment.relativePath.split(
            separator: "/", omittingEmptySubsequences: false)
          return !attachment.relativePath.hasPrefix("/") && !parts.isEmpty && !parts.contains("")
            && !parts.contains(".") && !parts.contains("..")
        }
    }
  }
  private static func decode(_ payload: String, chatID: ChatID) throws -> [SendCommand] {
    guard payload.utf8.count <= maximumPayloadBytes else { throw RepoError.corrupt }
    let commands: [SendCommand]
    do { commands = try JSONDecoder().decode([SendCommand].self, from: Data(payload.utf8)) } catch {
      throw RepoError.corrupt
    }
    guard valid(commands, chatID: chatID) else { throw RepoError.corrupt }
    return commands
  }
  static func load(_ db: SQLiteConnection, chatID: ChatID) throws -> [SendCommand]? {
    guard
      let row = try db.rows(
        "SELECT payload FROM media_selection_intents WHERE chatID=?", [.integer(chatID)]
      ).first
    else { return nil }
    return try decode(row["payload"]!.string, chatID: chatID)
  }
  static func save(_ db: SQLiteConnection, chatID: ChatID, commands: [SendCommand]?) throws {
    guard let commands else {
      try db.execute("DELETE FROM media_selection_intents WHERE chatID=?", [.integer(chatID)])
      return
    }
    guard valid(commands, chatID: chatID) else { throw RepoError.invalidInput }
    let data = try JSONEncoder().encode(commands)
    guard data.count <= maximumPayloadBytes else { throw RepoError.invalidInput }
    try db.execute(
      "INSERT OR REPLACE INTO media_selection_intents(chatID,payload) VALUES(?,?)",
      [.integer(chatID), .text(String(decoding: data, as: UTF8.self))])
  }
  /// Обходит всю таблицу, поскольку очистка не должна принять неполную страницу за полный список ещё
  /// используемых оригиналов.
  static func references(_ db: SQLiteConnection) throws -> Set<String> {
    var paths = Set<String>()
    try db.forEachRow("SELECT chatID,payload FROM media_selection_intents", []) { row in
      let commands = try decode(row["payload"]!.string, chatID: row["chatID"]!.int)
      for command in commands {
        for asset in command.attachments { paths.insert(asset.relativePath) }
      }
      return true
    }
    return paths
  }
}
