// Устанавливаем сохранённую историю и файлы во временное хранилище. Проверки используют один
// набор из десяти тысяч сообщений и получают одинаковые данные после повторного запуска.

@testable import Kandinsky
import Foundation
import CryptoKit
import SQLite3
import Darwin

private struct SeedFile: Decodable {
  let id: String
  let fileName: String
  let relativePath: String
  let sha256: String
  let mime: String
  let byteSize: Int64
  let width: Int
  let height: Int
  let durationMs: Int64
}
private struct SeedManifest: Decodable {
  let version: String
  let seedSha256: String
  let files: [SeedFile]
}
private struct SeedChat: Decodable {
  let id: Int64
  let title: String
  let pinned: Bool
  let unreadCount: Int
}
private struct SeedMessage: Decodable {
  let id: Int64
  let chatID: Int64
  let sortKey: Int64
  let savedAtMs: Int64
  let kind: String
  let text: String
  let caption: String
  let direction: String
  let attachmentFileIDs: [String]
}
private struct SeedDocument: Decodable {
  let version: String
  let chats: [SeedChat]
  let messages: [SeedMessage]
}
final class SeedInstaller: @unchecked Sendable {
  private let store: SQLiteStore
  // Получаем хранилище, в которое будут записываться история и признаки готовности. Очередь базы
  // задаёт порядок этой записи.
  init(store: SQLiteStore) { self.store = store }
  // Читаем файл порциями по 65 536 байт и считаем контрольную сумму. Это даёт сверку целого файла
  // без выделения памяти под него целиком.
  private static func sha(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 65536), !data.isEmpty { hasher.update(data: data) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
  // Сверяем версию, контрольные суммы и число строк. Сначала сохраняем проверенные файлы, затем
  // одной записью базы добавляем историю и отметку готовности, чтобы повтор после сбоя не создал
  // дубли.
  func installIfNeeded(
    version: String = "v1", corpusURL: URL,
    onProgress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws {
    guard version == "v1" else { throw RepoError.invalidInput }
    try await store.perform { [store] db in
      try SeedMediaInstaller.install(root: store.root, fixtures: corpusURL)
      try SeedMediaPreviews.install(db, fixtures: corpusURL)
      if try db.rows("SELECT value FROM metadata WHERE key='seed'").first?["value"]?.string
        == version
      {
        return
      }
      let decoder = JSONDecoder()
      let manifest = try decoder.decode(
        SeedManifest.self, from: Data(contentsOf: corpusURL.appendingPathComponent("manifest.json"))
      )
      let seedData = try Data(contentsOf: corpusURL.appendingPathComponent("seed-v1.json"))
      let seedHash = SHA256.hash(data: seedData).map { String(format: "%02x", $0) }.joined()
      guard manifest.version == version, manifest.seedSha256 == seedHash,
        manifest.files.count == 329
      else { throw RepoError.corrupt }
      let document = try decoder.decode(SeedDocument.self, from: seedData)
      guard document.version == version, document.messages.filter({ $0.chatID == 4 }).count == 10000
      else { throw RepoError.corrupt }
      let directory = store.root.appendingPathComponent("media/seed")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var fileMap: [String: SeedFile] = [:]
      for (index, file) in manifest.files.enumerated() {
        guard !file.fileName.contains("/"), file.fileName != ".", file.fileName != "..",
          file.relativePath == "seed/" + file.fileName, fileMap[file.id] == nil
        else { throw RepoError.corrupt }
        fileMap[file.id] = file
        let destination = directory.appendingPathComponent(file.fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
          guard try Self.sha(destination) == file.sha256 else { throw RepoError.corrupt }
        } else {
          let temporary = directory.appendingPathComponent(
            "." + file.fileName + "-" + UUID().uuidString + ".tmp")
          defer { try? FileManager.default.removeItem(at: temporary) }
          try FileManager.default.copyItem(
            at: corpusURL.appendingPathComponent("media").appendingPathComponent(file.fileName),
            to: temporary)
          guard try Self.sha(temporary) == file.sha256 else { throw RepoError.corrupt }
          let handle = try FileHandle(forWritingTo: temporary)
          do {
            try handle.synchronize()
            try handle.close()
          } catch {
            try? handle.close()
            throw error
          }
          try FileManager.default.moveItem(at: temporary, to: destination)
        }
        if index % 64 == 0 {
          let value = Double(index) / Double(manifest.files.count) * 0.6
          DispatchQueue.main.async { onProgress(value) }
        }
      }
      let fd = Darwin.open(directory.path, O_RDONLY)
      guard fd >= 0 else { throw RepoError.io }
      defer { Darwin.close(fd) }
      guard fsync(fd) == 0 else { throw RepoError.io }
      if store.faults.consume(.storageFull) { throw SQLiteFailure(code: SQLITE_FULL) }
      try db.transaction {
        guard
          try db.scalar(
            "SELECT COUNT(*) FROM messages WHERE id BETWEEN 100001 AND 110000 OR id IN(21,22,23)")
            == 0
        else { throw RepoError.corrupt }
        for chat in document.chats {
          try db.execute(
            """
            INSERT OR IGNORE INTO chats(id,title,avatarKind,updatedSortKey,unreadCount,\
            pinned) \
            VALUES(?,?,'initial',0,?,?)
            """,
            [
              .integer(chat.id), .text(chat.title), .integer(Int64(chat.unreadCount)),
              .integer(chat.pinned ? 1 : 0)
            ])
        }
        for (index, row) in document.messages.enumerated() {
          guard MessageKind(rawValue: row.kind) != nil,
            MessageDirection(rawValue: row.direction) != nil
          else { throw RepoError.corrupt }
          try db.execute(
            """
            INSERT INTO messages(id,chatId,sortKey,kind,text,caption,replyToId,revision,\
            savedAt,direction,searchText) \
            VALUES(?,?,?,?,?,?,NULL,1,?,?,?)
            """,
            [
              .integer(row.id), .integer(row.chatID), .integer(row.sortKey), .text(row.kind),
              .text(row.text), .text(row.caption), .integer(row.savedAtMs), .text(row.direction),
              .text((row.text + " " + row.caption).lowercased())
            ])
          for (ordinal, id) in row.attachmentFileIDs.enumerated() {
            guard let file = fileMap[id] else { throw RepoError.corrupt }
            try db.execute(
              """
              INSERT INTO attachments(id,messageId,relativePath,mime,byteSize,width,height,\
              durationMs,thumbnailKey,orientation) \
              VALUES(?,?,?,?,?,?,?,?,?,1)
              """,
              [
                .text("seed-\(row.id)-\(ordinal)"), .integer(row.id), .text(file.relativePath),
                .text(file.mime), .integer(file.byteSize), .integer(Int64(file.width)),
                .integer(Int64(file.height)),
                file.durationMs > 0 ? .integer(file.durationMs) : .null, .text("seed-thumb-" + id)
              ])
          }
          if index % 1000 == 0 {
            let value = 0.6 + Double(index) / Double(document.messages.count) * 0.4
            DispatchQueue.main.async { onProgress(value) }
          }
        }
        for chat in document.chats {
          let last = try db.rows(
            "SELECT id,sortKey FROM messages WHERE chatId=? ORDER BY sortKey DESC,id DESC LIMIT 1",
            [.integer(chat.id)]
          ).first
          try db.execute(
            "UPDATE chats SET lastMessageId=?,updatedSortKey=? WHERE id=?",
            [last?["id"] ?? .null, last?["sortKey"] ?? .integer(0), .integer(chat.id)])
        }
        try db.execute(
          "INSERT OR REPLACE INTO metadata(key,value) VALUES('seed',?)", [.text(version)])
        if store.faults.consume(.beforeCommit) { throw RepoError.io }
      }
      if store.faults.consume(.afterCommitBeforeReply) { throw RepoError.io }
      DispatchQueue.main.async { onProgress(1) }
    }
  }
}
