@testable import Kandinsky
import Foundation
import CryptoKit

enum SeedMediaInstaller {
  private struct Record: Decodable {
    let id: String, fileName: String, relativePath: String, sha256: String, mime: String
    let byteSize: Int64, width: Int, height: Int, orientation: Int
  }
  private struct Document: Decodable {
    let version: Int
    let chatId: Int64
    let files: [Record]
  }
  private static func records(_ fixtures: URL) throws -> [Record] {
    let data = try Data(contentsOf: fixtures.appendingPathComponent("real-media/manifest.json"))
    guard data.count <= 262144 else { throw RepoError.corrupt }
    let document = try JSONDecoder().decode(Document.self, from: data)
    guard document.version == 1, document.chatId == 1352, !document.files.isEmpty,
      document.files.count <= 32
    else { throw RepoError.corrupt }
    var ids = Set<String>(), total: Int64 = 0
    for file in document.files {
      let suffix: [String: String] = [
        "image/jpeg": ".jpg", "video/mp4": ".mp4", "image/gif": ".gif"
      ]
      guard file.id.range(of: "^backend-[0-9a-f]{32}$", options: .regularExpression) != nil,
        let ext = suffix[file.mime], file.fileName == file.id + ext,
        file.relativePath == "seed/" + file.fileName,
        file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        file.byteSize > 0, file.byteSize <= 32 * 1024 * 1024, file.width > 0, file.width <= 16384,
        file.height > 0, file.height <= 16384,
        (1...8).contains(file.orientation), ids.insert(file.id).inserted
      else { throw RepoError.corrupt }
      total += file.byteSize
      guard total <= 32 * 1024 * 1024 else { throw RepoError.corrupt }
    }
    return document.files
  }
  private static func matches(_ file: URL, record: Record) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256(), size: Int64 = 0
    while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
      size += Int64(chunk.count)
      guard size <= record.byteSize else { return false }
      hash.update(data: chunk)
    }
    return size == record.byteSize
      && hash.finalize().map { String(format: "%02x", $0) }.joined() == record.sha256
  }
  static func install(root: URL, fixtures: URL) throws {
    let values = try records(fixtures), fm = FileManager.default
    let directory = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(
      "media/seed")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path else {
      throw RepoError.corrupt
    }
    for record in values {
      let destination = directory.appendingPathComponent(record.fileName)
      guard destination.resolvingSymlinksInPath().path == destination.path else {
        throw RepoError.corrupt
      }
      if fm.fileExists(atPath: destination.path) {
        guard try matches(destination, record: record) else { throw RepoError.corrupt }
        continue
      }
      let temporary = directory.appendingPathComponent(
        "." + record.fileName + "-" + UUID().uuidString + ".tmp")
      defer { try? fm.removeItem(at: temporary) }
      try fm.copyItem(
        at: fixtures.appendingPathComponent("real-media/" + record.fileName), to: temporary)
      guard try matches(temporary, record: record) else { throw RepoError.corrupt }
      let handle = try FileHandle(forWritingTo: temporary)
      do {
        try handle.synchronize()
        try handle.close()
      } catch {
        try? handle.close()
        throw error
      }
      try fm.moveItem(at: temporary, to: destination)
    }
  }
}
