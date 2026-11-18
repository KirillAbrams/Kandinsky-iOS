import XCTest
@testable import Kandinsky
@MainActor final class HistoryIndexTests: XCTestCase {
  private func row(_ id: Int64, _ height: Double = 44) -> IndexedRow {
    IndexedRow(
      messageID: id, order: OrderKey(sortKey: id, messageID: id), estimatedHeight: height,
      revision: 1)
  }
  func testPrependDeleteResizeAndPageBounds() throws {
    let index = HistoryIndex()
    _ = try index.replace(
      rows: (1...10000).map { row(Int64($0)) }, anchor: ReadingAnchor(), viewport: 640)
    var anchor = ReadingAnchor(messageID: 5000, fraction: 0.25, followsBottom: false)
    let initial = index.offset(for: anchor, viewport: 640)
    XCTAssertEqual(initial, 4999 * 44 + 11)
    let shifted = try index.replace(rows: [row(0)] + index.rows, anchor: anchor, viewport: 640)
    XCTAssertEqual(shifted, initial + 44)
    XCTAssertEqual(index.anchorAt(offset: shifted).messageID, 5000)
    let changed = try index.updateHeight(id: 100, height: 100, anchor: anchor, viewport: 640)
    XCTAssertEqual(changed, shifted + 56)
    let deleted = try index.replace(
      rows: index.rows.filter { $0.messageID != 5000 }, anchor: anchor, viewport: 640)
    XCTAssertEqual(index.anchorAt(offset: deleted).messageID, 5001)
    anchor = index.anchorAt(offset: deleted)
    XCTAssertEqual(index.offset(for: anchor, viewport: 900), deleted, accuracy: 0.0001)
    XCTAssertThrowsError(try index.replace(rows: [row(1), row(1)], anchor: anchor, viewport: 640))
    let window = PageWindow(chatID: 4)
    let generation = window.generation
    for page in 0..<5 {
      let messages = (0..<128).map { n -> Message in
        let id = Int64(page * 128 + n + 1)
        return Message(
          id: id, chatID: 4, order: OrderKey(sortKey: id, messageID: id), direction: .incoming,
          savedAtMs: 1, kind: .text, text: "x", caption: "", replyToID: nil, revision: 1,
          attachments: [])
      }
      window.apply(
        HistoryPage(rows: messages, before: nil, after: nil), chatID: 4, generation: generation)
      XCTAssertLessThanOrEqual(window.loadedCount, 384)
    }
    XCTAssertEqual(window.loadedRows.first?.id, 257)
    window.close()
    window.apply(HistoryPage(rows: [], before: nil, after: nil), chatID: 4, generation: generation)
    XCTAssertEqual(window.loadedCount, 0)
  }
  /// Слишком большой, повторный либо чужой набор не должен заменить действующие строки.
  func testSeedKnownRowsPreservesBoundsAndRejectsInvalidOrClosedSeeds() {
    func message(_ id: Int64, _ chat: Int64 = 4) -> Message {
      Message(
        id: id, chatID: chat, order: OrderKey(sortKey: id, messageID: id), direction: .incoming,
        savedAtMs: 1, kind: .text, text: "x", caption: "", replyToID: nil, revision: 1,
        attachments: [])
    }
    let rows = (1...384).map { message(Int64($0)) }, window = PageWindow(chatID: 4)
    window.seedKnownRows(rows)
    XCTAssertEqual(window.loadedRows.map(\.id), rows.map(\.id))
    for invalid in [rows + [message(385)], [message(1), message(1)], [message(1, 2)]] {
      window.seedKnownRows(invalid)
      XCTAssertEqual(window.loadedRows.map(\.id), rows.map(\.id))
    }
    window.apply(
      HistoryPage(rows: [message(385)], before: nil, after: nil), chatID: 4,
      generation: window.generation)
    XCTAssertEqual(window.loadedCount, 257)
    XCTAssertEqual(window.loadedRows.first?.id, 129)
    window.close()
    window.seedKnownRows(rows)
    XCTAssertEqual(window.loadedCount, 0)
  }
  func testIndependentLinearOracleAndHundredThousandIndex() throws {
    let index = HistoryIndex()
    var rows = (1...10000).map { row(Int64($0)) }
    let url = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("oracles/history-operations-v1.json")
    let oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    for op in oracle["operations"] as! [[String: Any]] {
      let id = (op["id"] as! NSNumber).int64Value
      switch op["kind"] as! String {
      case "insert":
        rows.append(row(id, (op["height"] as! NSNumber).doubleValue))
        rows.sort { $0.order < $1.order }
      case "delete": rows.removeAll { $0.messageID == id }
      default:
        rows = rows.map {
          $0.messageID == id ? row(id, (op["height"] as! NSNumber).doubleValue) : $0
        }
      }
      _ = try index.replace(rows: rows, anchor: ReadingAnchor(), viewport: 640)
      let offset = (op["offset"] as! NSNumber).doubleValue
      XCTAssertEqual(
        index.anchorAt(offset: offset).messageID, (op["expectedID"] as! NSNumber).int64Value)
      XCTAssertEqual(
        index.totalHeight, (op["expectedTotal"] as! NSNumber).doubleValue, accuracy: 0.0001)
    }
    _ = try index.replace(
      rows: (1...100000).map { row(Int64($0)) }, anchor: ReadingAnchor(), viewport: 640)
    XCTAssertEqual(index.anchorAt(offset: 4399956).messageID, 100000)
    XCTAssertLessThanOrEqual(
      index.visible(offset: 1000, height: 100000, maxFragments: 128).count, 128)
    let bottom = index.offset(for: ReadingAnchor(followsBottom: true), viewport: 640)
    XCTAssertEqual(bottom, 4400000 - 640)
    _ = try index.replace(rows: [], anchor: ReadingAnchor(), viewport: 640)
    XCTAssertTrue(index.visible(offset: 0, height: 640).isEmpty)
    XCTAssertNil(index.anchorAt(offset: 0).messageID)
  }
}

extension HistoryIndexTests {
  func testDecoratedLayoutMatchesIndependentCalendarAndLinearOracle() throws {
    for zone in ["UTC", "America/New_York", "Asia/Kathmandu"] {
      let tz = TimeZone(identifier: zone)!, index = HistoryIndex(dayGap: 32, timeZone: tz)
      index.configureInsets(top: 100, bottom: 90)
      let rows: [IndexedRow] = (1...6000).map { n -> IndexedRow in
        let id = Int64(n), stamp: Int64 = 1793484000000 + Int64(n) * 300000
        let h = 44.0 + Double(n % 7) * 3.25
        return IndexedRow(
          messageID: id, order: OrderKey(sortKey: id, messageID: id), estimatedHeight: h,
          revision: 1, savedAtMs: stamp)
      }
      _ = try index.replace(rows: rows, anchor: ReadingAnchor(), viewport: 640)
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = tz
      var previous: Date?, y = 100.0, tops: [Double] = [], starts: [Double] = []
      for row in rows {
        starts.append(y)
        let date = Date(timeIntervalSince1970: Double(row.savedAtMs!) / 1000)
        if previous == nil || !calendar.isDate(previous!, inSameDayAs: date) { y += 32 }
        previous = date
        tops.append(y)
        y += row.estimatedHeight
      }
      XCTAssertEqual(index.totalHeight, y + 90, accuracy: 0.000001)
      for n in 0..<1000 {
        let target = Double((n * 7919) % 10000) / 10000 * (index.totalHeight - 640)
        let expected = starts.lastIndex(where: { $0 <= target }) ?? 0
        XCTAssertEqual(index.anchorAt(offset: target).messageID, rows[expected].messageID)
        XCTAssertEqual(index.top(of: rows[n * 5].messageID)!, tops[n * 5], accuracy: 0.000001)
        let anchor = index.anchorAt(offset: target)
        XCTAssertEqual(index.offset(for: anchor, viewport: 640), target, accuracy: 0.000001)
      }
    }
  }
  /// Пустая история не должна сохранять высоту и разделители.
  func testDaySpaceInsetsAndHeightChangesPreserveAnchor() throws {
    let index = HistoryIndex(dayGap: 32, timeZone: TimeZone(secondsFromGMT: 0)!)
    index.configureInsets(top: 100, bottom: 90)
    let rows = [
      IndexedRow(
        messageID: 1, order: OrderKey(sortKey: 1, messageID: 1), estimatedHeight: 40, revision: 1,
        savedAtMs: 1000),
      IndexedRow(
        messageID: 2, order: OrderKey(sortKey: 2, messageID: 2), estimatedHeight: 60, revision: 1,
        savedAtMs: 2000),
      IndexedRow(
        messageID: 3, order: OrderKey(sortKey: 3, messageID: 3), estimatedHeight: 80, revision: 1,
        savedAtMs: 86401000)
    ]
    _ = try index.replace(rows: rows, anchor: ReadingAnchor(), viewport: 100)
    XCTAssertEqual(index.totalHeight, 434)
    XCTAssertEqual(index.top(of: 1), 132)
    XCTAssertEqual(index.top(of: 2), 172)
    XCTAssertEqual(index.top(of: 3), 264)
    XCTAssertEqual(index.days(offset: 110, height: 150).map(\.messageID), [1, 3])
    let header = index.anchorAt(offset: 110)
    XCTAssertEqual(index.offset(for: header, viewport: 100), 110)
    let anchor = index.anchorAt(offset: 275)
    XCTAssertEqual(try index.updateHeight(id: 1, height: 90, anchor: anchor, viewport: 100), 325)
    _ = try index.replace(rows: [], anchor: ReadingAnchor(), viewport: 100)
    XCTAssertEqual(index.totalHeight, 0)
    XCTAssertTrue(index.days(offset: 0, height: 100).isEmpty)
  }
}
