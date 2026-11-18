import XCTest
@testable import Kandinsky
@MainActor final class RecoveryTests: XCTestCase {
  private func wait(_ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(8)
    while Date() < end {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(condition(), "Native release/preparation exceeded8seconds")
  }
  func testTwoRuntimesCannotCreateOverlappingNativePlayers() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let root = Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)!
    let data =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
    let file =
      (data["files"] as! [[String: Any]]).first { $0["mime"] as? String == "video/mp4" }![
        "fileName"] as! String
    let d = try await media.stage(
      sourceURL: root.appendingPathComponent("media/" + file), mime: "video/mp4")
    let a = Attachment(
      id: d.id, relativePath: d.relativePath, mime: d.mime, byteSize: d.byteSize,
      rawWidth: d.rawWidth, rawHeight: d.rawHeight, orientation: d.orientation,
      durationMs: d.durationMs, thumbnailKey: d.thumbnailKey)
    let first = MediaAdmission(), second = MediaAdmission(),
      c1 = MediaCoordinator(admission: first, media: media),
      c2 = MediaCoordinator(admission: second, media: media)
    c1.play(target: PlaybackTarget(attachment: a, messageID: 1))
    try await wait { c1.isReady }
    c2.play(target: PlaybackTarget(attachment: a, messageID: 2))
    try await wait { c2.nativeItemAttached || c2.lastError != nil }
    XCTAssertLessThanOrEqual(
      c1.activePlayerCount + c2.activePlayerCount, 1,
      "One native player is a PROCESS invariant, including overlapping runtimes")
    c1.close()
    try await wait { first.playbackActiveCount == 0 }
    c2.stop()
    try await wait { second.playbackActiveCount == 0 }
    c2.play(target: PlaybackTarget(attachment: a, messageID: 3))
    try await wait { c2.isReady }
    XCTAssertEqual(c2.activePlayerCount, 1)
    c2.close()
    try await wait { second.playbackActiveCount == 0 }
    first.close()
    second.close()
    media.close()
    try await h.close()
  }

  func testRealSQLiteFullRollsBackAndExactRetryWorks() async throws {
    let h = try await RepositoryHarness.open()
    _ = try await h.repo.send(SendCommand(operationID: "preserved", chatID: 2, text: "keep"))
    try await h.repo.saveDraft(chatID: 2, draft: Draft(text: "durable draft", revision: 9))
    let pages = try await h.store.perform { db in try db.scalar("PRAGMA page_count") }
    _ = try await h.store.perform { db in try db.scalar("PRAGMA max_page_count=\(pages)") }
    let command = SendCommand(
      operationID: "actual-full", chatID: 2, text: String(repeating: "x", count: 220000))
    do {
      _ = try await h.repo.send(command)
      XCTFail("Real SQLITE_FULL required")
    } catch { XCTAssertEqual(error as? RepoError, .storageFull) }
    XCTAssertEqual(try h.rawScalar("SELECT COUNT(*) FROM messages"), 1)
    XCTAssertEqual(try h.integrity(), "ok")
    let saved = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(saved.text, "durable draft")
    _ = try await h.store.perform { db in try db.scalar("PRAGMA max_page_count=1000000") }
    _ = try await h.repo.send(command)
    _ = try await h.repo.send(command)
    XCTAssertEqual(try h.rawScalar("SELECT COUNT(*) FROM messages"), 2)
    try await h.close()
  }
  // Принудительный обрыв записи включён в MediaStore только в отладочной сборке.
  #if DEBUG
  func testPartialStagingNoSpaceCleansTempAndPreservesCommittedBytes() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let root = Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)!
    let data =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
    let file =
      (data["files"] as! [[String: Any]]).first { $0["mime"] as? String == "image/jpeg" }![
        "fileName"] as! String
    let source = root.appendingPathComponent("media/" + file),
      d = try await media.stage(sourceURL: source, mime: "image/jpeg")
    _ = try await h.repo.send(
      SendCommand(operationID: "original", chatID: 2, kind: .photo, attachments: [d]))
    let originalURL = try media.fileURL(d.relativePath), bytes = try Data(contentsOf: originalURL)
    h.faults.arm(.storageFull)
    do {
      _ = try await media.stage(sourceURL: source, mime: "image/jpeg")
      XCTFail("Bounded staging write fault must report ENOSPC")
    } catch { XCTAssertEqual(error as? MediaError, .storageFull) }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: h.root.appendingPathComponent("media/staging").path
      ).count, 0)
    try await media.recover()
    XCTAssertEqual(try Data(contentsOf: originalURL), bytes)
    XCTAssertEqual(try h.rawScalar("SELECT COUNT(*) FROM attachments"), 1)
    media.close()
    try await h.close()
  }
  #endif

  func testSQLiteSubmissionQueueIsBoundedWhileWriterHeld() async throws {
    let h = try await RepositoryHarness.open(), held = DispatchSemaphore(value: 0),
      started = expectation(description: "native SQLite writer held")
    let writer = Task {
      try await h.store.perform { db in
        _ = try db.scalar("SELECT 1")
        started.fulfill()
        held.wait()
        return 1
      }
    }
    await fulfillment(of: [started], timeout: 3)
    defer { held.signal() }
    var attempted = 0
    let requests = (0..<100).map { n in
      Task { () -> Bool in
        attempted += 1
        do {
          _ = try await h.store.perform { db in try db.scalar("SELECT \(n)") }
          return true
        } catch { return false }
      }
    }
    try await wait { attempted == 100 }
    held.signal()
    var accepted = 0
    for request in requests { if await request.value { accepted += 1 } }
    _ = try await writer.value
    XCTAssertEqual(accepted, 64, "At most64 queued SQL jobs beside the active native writer")
    try await h.close()
  }
}
