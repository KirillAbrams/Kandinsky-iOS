import Foundation
struct HistoryDay {
  let messageID: MessageID
  let timestamp: Int64
  let top: Double
  let height: Double
}
final class HistoryIndex {
  private(set) var rows: [IndexedRow] = []
  private var tree: [Double] = [0], leading: [Double] = []
  private var positions: [MessageID: Int] = [:]
  private let dayGap: Double, timeZone: TimeZone
  private var topInset = 0.0, bottomInset = 0.0
  private(set) var totalHeight: Double = 0
  private(set) var geometryRevision = 0
  init(dayGap: Double = 0, timeZone: TimeZone = .current) {
    precondition(dayGap.isFinite && dayGap >= 0)
    self.dayGap = dayGap
    self.timeZone = timeZone
  }
  func configureInsets(top: Double, bottom: Double) {
    precondition(top.isFinite && bottom.isFinite && top >= 0 && bottom >= 0)
    guard top != topInset || bottom != bottomInset else { return }
    if !rows.isEmpty { totalHeight += top - topInset + bottom - bottomInset }
    topInset = top
    bottomInset = bottom
    geometryRevision &+= 1
  }
  private func stamp(_ row: IndexedRow) -> Int64 { row.savedAtMs ?? row.order.sortKey }
  private func day(_ row: IndexedRow) -> Int64 {
    let ms = Double(stamp(row)), date = Date(timeIntervalSince1970: ms / 1000)
    return Int64(floor((ms + Double(timeZone.secondsFromGMT(for: date)) * 1000) / 86400000))
  }
  func replace(rows: [IndexedRow], anchor: ReadingAnchor, viewport: Double) throws -> Double {
    let sorted = rows.sorted { $0.order < $1.order }
    guard Set(sorted.map(\.messageID)).count == sorted.count,
      sorted.allSatisfy({
        $0.messageID == $0.order.messageID && $0.estimatedHeight.isFinite && $0.estimatedHeight > 0
      })
    else { throw RepoError.invalidInput }
    let oldOrder = anchor.messageID.flatMap { positions[$0] }.map { self.rows[$0].order }
    self.rows = sorted
    geometryRevision &+= 1
    positions = [:]
    tree = Array(repeating: 0, count: sorted.count + 1)
    leading = Array(repeating: 0, count: sorted.count)
    totalHeight = sorted.isEmpty ? 0 : topInset + bottomInset
    var previous: Int64?
    for (i, row) in sorted.enumerated() {
      positions[row.messageID] = i
      if dayGap > 0 {
        let current = day(row)
        if previous != current { leading[i] = dayGap }
        previous = current
      }
      let h = row.estimatedHeight + leading[i]
      tree[i + 1] += h
      totalHeight += h
      let parent = (i + 1) + ((i + 1) & -(i + 1))
      if parent < tree.count { tree[parent] += tree[i + 1] }
    }
    var restored = anchor
    if let id = anchor.messageID, positions[id] == nil, let oldOrder, !sorted.isEmpty {
      var lo = 0, hi = sorted.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if sorted[mid].order < oldOrder { lo = mid + 1 } else { hi = mid }
      }
      restored.messageID = sorted[min(lo, sorted.count - 1)].messageID
    }
    return offset(for: restored, viewport: viewport)
  }
  func prefix(_ count: Int) -> Double {
    var n = min(max(0, count), rows.count), sum = topInset
    while n > 0 {
      sum += tree[n]
      n -= n & -n
    }
    return sum
  }
  func position(of id: MessageID) -> Int? { positions[id] }
  func refreshRevision(_ message: Message) {
    guard let i = positions[message.id], rows[i].order == message.order,
      rows[i].revision < message.revision
    else { return }
    let old = rows[i]
    rows[i] = IndexedRow(
      messageID: old.messageID, order: old.order, estimatedHeight: old.estimatedHeight,
      revision: message.revision, savedAtMs: old.savedAtMs)
  }
  func row(at index: Int) -> IndexedRow? { rows.indices.contains(index) ? rows[index] : nil }
  /// Добавляет промежуток его разделителя дня, чтобы положение относилось к самому сообщению, а не к
  /// заголовку перед ним.
  func top(of id: MessageID) -> Double? { positions[id].map { prefix($0) + leading[$0] } }
  func height(of id: MessageID) -> Double? { positions[id].map { rows[$0].estimatedHeight } }
  private func seek(_ value: Double) -> Int {
    guard !rows.isEmpty else { return 0 }
    let content = totalHeight - topInset - bottomInset,
      target = max(0, min(value - topInset, max(0, content.nextDown)))
    var index = 0, sum = 0.0, step = 1
    while step <= rows.count / 2 { step *= 2 }
    while step > 0 {
      let next = index + step
      if next < tree.count && sum + tree[next] <= target {
        index = next
        sum += tree[next]
      }
      step /= 2
    }
    return min(index, rows.count - 1)
  }
  /// Запоминаем сообщение и смещение внутри него, чтобы после изменения высоты строк сохранить место чтения.
  func anchorAt(offset: Double) -> ReadingAnchor {
    guard !rows.isEmpty else { return ReadingAnchor(followsBottom: false) }
    let i = seek(offset), r = rows[i], top = prefix(i) + leading[i]
    return ReadingAnchor(
      messageID: r.messageID, fraction: max(0, min(1, (offset - top) / r.estimatedHeight)),
      screenDelta: max(0, top - offset), followsBottom: false)
  }
  func offset(for anchor: ReadingAnchor, viewport: Double) -> Double {
    if anchor.followsBottom { return max(0, totalHeight - max(0, viewport)) }
    guard let id = anchor.messageID, let i = positions[id] else { return 0 }
    return max(
      0,
      min(
        prefix(i) + leading[i] + max(0, min(1, anchor.fraction)) * rows[i].estimatedHeight
          - anchor.screenDelta, max(0, totalHeight - max(0, viewport))))
  }
  func updateHeight(id: MessageID, height: Double, anchor: ReadingAnchor, viewport: Double) throws
    -> Double
  {
    guard height.isFinite, height > 0, let i = positions[id] else { throw RepoError.invalidInput }
    let old = rows[i], delta = height - old.estimatedHeight
    guard delta != 0 else { return offset(for: anchor, viewport: viewport) }
    geometryRevision &+= 1
    rows[i] = IndexedRow(
      messageID: id, order: old.order, estimatedHeight: height, revision: old.revision,
      savedAtMs: old.savedAtMs)
    var n = i + 1
    while n < tree.count {
      tree[n] += delta
      n += n & -n
    }
    totalHeight += delta
    return offset(for: anchor, viewport: viewport)
  }
  func visible(offset: Double, height: Double, overscan: Int = 1, maxFragments: Int = 128) -> Range<
    Int
  > {
    guard !rows.isEmpty, height > 0, maxFragments > 0 else { return 0..<0 }
    let start = max(0, seek(offset) - max(0, overscan)),
      end = min(
        rows.count, seek(offset + height) + 1 + max(0, overscan), start + min(128, maxFragments))
    return start..<max(start, end)
  }
  func days(offset: Double, height: Double) -> [HistoryDay] {
    guard dayGap > 0 else { return [] }
    return visible(offset: offset, height: height).compactMap { i in
      let y = prefix(i)
      return leading[i] > 0 && y + leading[i] > offset && y < offset + height
        ? HistoryDay(
          messageID: rows[i].messageID, timestamp: stamp(rows[i]), top: y, height: leading[i]) : nil
    }
  }
}
