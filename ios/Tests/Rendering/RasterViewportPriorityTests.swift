import XCTest
import UIKit
@testable import Kandinsky

@MainActor final class RasterViewportPriorityTests: XCTestCase {
  /// Приоритет подготовки не должен менять хронологический порядок сохранённых слоёв.
  func testVisibleBodyPublishesBeforeQueuedOffscreenBodies() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...3 {
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text',?,?)",
            [
              .integer(Int64(n)), .text("Растр строки \(n)."),
              .integer(1_793_700_000_000 + Int64(n))
            ])
        }
      }
    }
    let rows = try await h.repo.history(PageRequest(chatID: 2)), container = CALayer(),
      scene = RetainedChatScene(container: container)
    let viewport = CGRect(x: 0, y: 2000, width: 390, height: 600)
    scene.viewport = viewport
    let queue = try XCTUnwrap(
      Mirror(reflecting: scene).children.first { $0.label == "rasterQueue" }?.value
        as? MediaDecodeQueue)
    let release = DispatchSemaphore(value: 0)
    defer {
      release.signal()
      scene.close()
    }
    let blocker = queue.submit(
      work: {
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        return 0
      }, dispose: { _ in }, completion: { _ in })
    defer { blocker.cancel() }
    let deadline = Date().addingTimeInterval(2)
    while queue.runningCount != 1, Date() < deadline {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(queue.runningCount, 1)
    let fragments = rows.rows.enumerated().map { index, row in
      let key = TextLayoutKey(
        messageID: row.id, revision: row.revision, width: 280, fontSize: 18, scale: 3)
      let prepared = PreparedText(message: row, key: key)
      return SceneFragment(
        prepared: prepared, part: 0,
        frame: CGRect(
          x: 18, y: CGFloat(index * 1000), width: prepared.width, height: prepared.blocks[0].height)
      )
    }
    scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: fragments))
    var publication: [MessageID] = []
    for node in (container.sublayers ?? []).compactMap({ $0 as? MessageLayer }) {
      let previous = node.onRecord
      node.onRecord = {
        previous?()
        if let id = node.fragment?.id.messageID { publication.append(id) }
      }
    }
    XCTAssertEqual(
      queue.pendingCount, 3, "Hold all three actual native raster jobs behind the owned worker")
    release.signal()
    let end = Date().addingTimeInterval(3)
    while publication.count < 3, Date() < end { try await Task.sleep(nanoseconds: 1_000_000) }
    print("KANDINSKY_RASTER_PRIORITY publication=\(publication)")
    XCTAssertEqual(publication.count, 3)
    XCTAssertEqual(
      publication.first, rows.rows.last?.id,
      "A currently visible message must publish before queued future-screen rasters")
    XCTAssertEqual(
      (container.sublayers ?? []).compactMap { ($0 as? MessageLayer)?.fragment?.id.messageID },
      rows.rows.map(\.id), "Priority must not change chronological native layer order")
    scene.close()
    try await h.close()
  }
}
