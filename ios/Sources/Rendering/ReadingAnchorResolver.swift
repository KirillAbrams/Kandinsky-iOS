import Foundation
enum ReadingAnchorResolver {
  static func afterRemoving(_ anchor: ReadingAnchor, rows: [IndexedRow], removed: Set<MessageID>)
    -> ReadingAnchor
  {
    guard !anchor.followsBottom, let anchorMessageID = anchor.messageID,
      removed.contains(anchorMessageID),
      let removedRowIndex = rows.firstIndex(where: { $0.messageID == anchorMessageID })
    else { return anchor }
    let nextVisibleRow = rows.dropFirst(removedRowIndex + 1).first {
      !removed.contains($0.messageID)
    }
    let previousVisibleRow = rows.prefix(removedRowIndex).reversed().first {
      !removed.contains($0.messageID)
    }
    return ReadingAnchor(
      messageID: (nextVisibleRow ?? previousVisibleRow)?.messageID, followsBottom: false,
      layoutVersion: anchor.layoutVersion)
  }
}
