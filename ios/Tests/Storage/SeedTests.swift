import XCTest
import ImageIO
import AVFoundation
@testable import Kandinsky
final class SeedTests: XCTestCase {
  func testCorpusFilesAndComposition() async throws {
    let directory = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil),
      "Native offline corpus bundled")
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as! [String: Any]
    let files = manifest["files"] as! [[String: Any]]
    XCTAssertEqual(files.count, 329)
    let seed =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: directory.appendingPathComponent("seed-v1.json"))) as! [String: Any]
    let rows = (seed["messages"] as! [[String: Any]]).filter { ($0["chatID"] as! Int) == 4 }
    XCTAssertEqual(rows.count, 10000)
    let counts = ["text", "photo", "voice", "video", "round", "gif"].map { kind in
      rows.filter { ($0["kind"] as! String) == kind }.count
    }
    XCTAssertEqual(counts, [6500, 2000, 700, 400, 200, 200])
    var photoBytes = 0
    for file in files {
      let url = directory.appendingPathComponent("media").appendingPathComponent(
        file["fileName"] as! String)
      let mime = file["mime"] as! String
      if mime.hasPrefix("image/") {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        if mime == "image/gif" { XCTAssertEqual(CGImageSourceGetCount(source), 8) }
        if mime == "image/jpeg" {
          photoBytes += (file["width"] as! Int) * (file["height"] as! Int) * 4
        }
      } else {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty)
        if mime == "video/mp4" {
          let video = try await asset.loadTracks(withMediaType: .video)
          XCTAssertFalse(video.isEmpty)
        }
      }
    }
    XCTAssertGreaterThan(photoBytes, 48 * 1024 * 1024)
  }
  /// Повтор не должен размножить исходные строки или удалить добавленное сообщение.
  func testSeedCompositionAndIdempotence() async throws {
    let corpus = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    var h = try await RepositoryHarness.open()
    try await SeedInstaller(store: h.store).installIfNeeded(corpusURL: corpus)
    let counts = try ["text", "photo", "voice", "video", "round", "gif"].map { kind in
      try h.rawScalar("SELECT COUNT(*) FROM messages WHERE chatId=4 AND kind='\(kind)'")
    }
    XCTAssertEqual(counts, [6500, 2000, 700, 400, 200, 200])
    XCTAssertEqual(try h.rawScalar("SELECT COUNT(*) FROM messages WHERE chatId=4"), 10000)
    let refs = try await h.store.perform { db in
      try db.rows("SELECT DISTINCT relativePath FROM attachments").map {
        $0["relativePath"]!.string
      }
    }
    XCTAssertGreaterThan(refs.count, 48)
    for path in refs {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: h.root.appendingPathComponent("media").appendingPathComponent(path).path))
    }
    let sent = try await h.repo.send(
      SendCommand(operationID: "user-after-seed", chatID: 4, text: "Пользовательское сообщение"))
    let id = try XCTUnwrap(sent.inserted.first?.id)
    h = try await h.reopen()
    try await SeedInstaller(store: h.store).installIfNeeded(corpusURL: corpus)
    XCTAssertEqual(try h.rawScalar("SELECT COUNT(*) FROM messages WHERE chatId=4"), 10001)
    XCTAssertEqual(try h.rawScalar("SELECT COUNT(*) FROM messages WHERE id=\(id)"), 1)
    XCTAssertEqual(try h.integrity(), "ok")
    try await h.close()
  }
}
