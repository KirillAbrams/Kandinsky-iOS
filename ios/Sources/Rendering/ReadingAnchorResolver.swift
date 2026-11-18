// При удалении строки, на которой держалось место чтения, выбираем ближайшее оставшееся
// сообщение. Это сохраняет положение человека в переписке после удаления результата.

import Foundation
enum ReadingAnchorResolver {
  // Сохраняем точку, если она уже следует за низом или её строка осталась. Для удалённой берём
  // первую целую ниже, а при её отсутствии последнюю выше. Если строк больше нет, оставляем точку
  // без номера.
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
