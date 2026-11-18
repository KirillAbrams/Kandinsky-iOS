import XCTest
@testable import Kandinsky
@MainActor final class HundredThousandStressTests: XCTestCase {
  func testNativeSQLiteKeysetAndBoundedWindowWithSameMediaPool() async throws {
    let h = try await RepositoryHarness.open()
    let corpus = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    try await SeedInstaller(store: h.store).installIfNeeded(corpusURL: corpus)
    let before = try h.rawScalar("SELECT COUNT(DISTINCT relativePath) FROM attachments")
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...9 {
          let offset = n * 1000000, sort = n * 100000000
          try db.execute(
            """
            INSERT INTO messages(id,chatId,sortKey,kind,text,caption,replyToId,\
            revision,savedAt,direction,searchText) SELECT id+\(offset),chatId,\
            sortKey+\(sort),kind,text,caption,NULL,revision,savedAt,direction,\
            searchText \
            FROM messages \
            WHERE chatId=4 AND id BETWEEN 100001 AND 110000
            """
          )
          try db.execute(
            """
            INSERT INTO attachments(id,messageId,relativePath,mime,byteSize,width,\
            height,durationMs,thumbnailKey,orientation) SELECT 'stress-\(n)-'||id,\
            messageId+\(offset),relativePath,mime,byteSize,width,height,durationMs,\
            thumbnailKey,orientation \
            FROM attachments \
            WHERE messageId BETWEEN 100001 AND 110000
            """
          )
        }
      }
    }
    XCTAssertEqual(try h.rawScalar("SELECT COUNT(*) FROM messages WHERE chatId=4"), 100000)
    XCTAssertEqual(try h.rawScalar("SELECT COUNT(DISTINCT relativePath) FROM attachments"), before)
    let start = ProcessInfo.processInfo.systemUptime
    let rows = try await h.repo.index(chatID: 4)
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    XCTAssertEqual(rows.count, 100000)
    let window = PageWindow(chatID: 4, repository: h.repo)
    var maximum = 0
    var times: [Double] = []
    for position in stride(from: 0, to: 100000, by: 8333) {
      let t = ProcessInfo.processInfo.systemUptime
      let page = try await window.request(
        PageRequest(chatID: 4, anchor: rows[position].order, direction: .around))
      times.append((ProcessInfo.processInfo.systemUptime - t) * 1000)
      XCTAssertFalse(page.rows.isEmpty)
      XCTAssertTrue(page.rows.contains { $0.id == rows[position].messageID })
      maximum = max(maximum, window.loadedCount)
      XCTAssertLessThanOrEqual(window.loadedCount, 384)
      for a in page.rows.flatMap({ $0.attachments }) {
        XCTAssertTrue(
          FileManager.default.fileExists(
            atPath: h.root.appendingPathComponent("media").appendingPathComponent(a.relativePath)
              .path))
      }
    }
    XCTAssertEqual(try h.integrity(), "ok")
    window.close()
    XCTAssertEqual(window.loadedCount, 0)
    let report: [String: Any] = [
      "metadataRows": rows.count, "metadataOpenMs": elapsed, "pageMs": times,
      "maxFullMessages": maximum, "distinctMediaPaths": before,
      "build": "Release test target; same immutable media pool"
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "100k-native-sqlite"
    attachment.lifetime = .keepAlways
    add(attachment)
    try await h.close()
  }
}
