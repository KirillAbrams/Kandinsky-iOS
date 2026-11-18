import XCTest
@testable import Kandinsky

final class MediaGalleryWindowTests: XCTestCase {
  private func row(_ id: Int64, count: Int = 1, chat: Int64 = 2, kind: MessageKind = .photo)
    -> Message
  {
    Message(
      id: id, chatID: chat, order: OrderKey(sortKey: id / 3, messageID: id), direction: .incoming,
      savedAtMs: id, kind: kind, text: "", caption: "Описание \(id)", replyToID: nil, revision: 1,
      attachments: (0..<count).map {
        Attachment(
          id: "a-\(id)-\($0)", relativePath: "network/\(id)-\($0).jpg", mime: "image/jpeg",
          byteSize: 12, rawWidth: 120, rawHeight: 80, orientation: 1, durationMs: 0,
          thumbnailKey: "")
      })
  }
  /// История другого чата не должна попасть в это окно.
  func testMixedHistoryMergePreservesSelectionAndOriginalAlbumOrder() {
    let seed = row(10, count: 3)
    var window = MediaGalleryWindow(seed: seed, attachmentIndex: 1)
    let page = HistoryPage(
      rows: [row(12), row(9, kind: .voice), seed, row(8), seed], before: nil, after: nil)
    XCTAssertTrue(window.merge(page))
    XCTAssertEqual(window.entries.map(\.id), ["8/0", "10/0", "10/1", "10/2", "12/0"])
    XCTAssertEqual(window.selected?.id, "10/1")
    XCTAssertEqual(window.neighbours.count, 3)
    XCTAssertFalse(window.select("missing"))
    XCTAssertEqual(window.selected?.id, "10/1")
    XCTAssertFalse(window.merge(HistoryPage(rows: [row(14, chat: 3)], before: nil, after: nil)))
    XCTAssertEqual(window.selected?.caption, "Описание 10")
  }
  func testForwardReverseTraversalMatchesIndependentFlattenedHistoryAndStaysBounded() throws {
    let rows = (1...300).map { row(Int64($0), count: 1 + $0 % 4) }
    let expected = (1...300).flatMap { id in (0..<(1 + id % 4)).map { "\(id)/\($0)" } }
    var window = MediaGalleryWindow(seed: rows[69], attachmentIndex: 1)
    var reference = try XCTUnwrap(expected.firstIndex(of: "70/1"))
    func page(_ id: Int64) -> HistoryPage {
      let lower = max(0, min(Int(id) - 17, rows.count - 32)), upper = min(rows.count, lower + 32)
      return HistoryPage(
        rows: Array(rows[lower..<upper]), before: lower > 0 ? rows[lower].order : nil,
        after: upper < rows.count ? rows[upper - 1].order : nil)
    }
    for direction in [1, -1] {
      for _ in 0..<320 {
        let selected = try XCTUnwrap(window.selected)
        if window.needsPage {
          XCTAssertTrue(window.merge(page(selected.messageID)))
          XCTAssertEqual(window.selected?.id, selected.id)
        }
        reference += direction
        XCTAssertTrue(window.select(expected[reference]))
        XCTAssertEqual(window.selected?.id, expected[reference])
        XCTAssertLessThanOrEqual(window.entries.count, 96)
        XCTAssertLessThanOrEqual(window.neighbours.count, 3)
      }
    }
  }
  /// Повторно подаёт исходный альбом при нехватке окна.
  func testOversizedAlbumCanBeTraversedWithoutLosingTrimmedAttachments() {
    let album = row(1, count: 200)
    var window = MediaGalleryWindow(seed: album, attachmentIndex: 150)
    for index in 151..<200 {
      if window.needsPage { _ = window.merge(HistoryPage(rows: [album], before: nil, after: nil)) }
      XCTAssertTrue(window.select("1/\(index)"))
      XCTAssertEqual(window.selected?.id, "1/\(index)")
      XCTAssertLessThanOrEqual(window.entries.count, 96)
    }
    for index in (0..<199).reversed() {
      if window.needsPage { _ = window.merge(HistoryPage(rows: [album], before: nil, after: nil)) }
      XCTAssertTrue(window.select("1/\(index)"))
      XCTAssertEqual(window.selected?.id, "1/\(index)")
    }
    XCTAssertFalse(window.select("1/-1"))
    XCTAssertEqual(window.selected?.id, "1/0")
  }
  func testDeletingSelectionChoosesAnAdjacentItemAndNeverImportsAnotherChat() {
    var window = MediaGalleryWindow(seed: row(3))
    _ = window.merge(HistoryPage(rows: [row(1), row(2), row(3), row(4)], before: nil, after: nil))
    let chat = ChatSummary(
      id: 2, title: "QA", lastPreview: "", lastSortKey: 4, lastSavedAtMs: 4, unreadCount: 0,
      pinned: false)
    window.apply(MessageDelta(removedIDs: [3], chat: chat))
    XCTAssertEqual(window.selected?.id, "4/0")
    window.apply(MessageDelta(removedIDs: [1, 2, 4], chat: chat))
    XCTAssertNil(window.selected)
    XCTAssertTrue(window.neighbours.isEmpty)
  }
}
