// Описывает ключ для повторного открытия видео. Номер сообщения, вложение и путь вместе отличают
// новый файл от прежнего.

import Foundation

struct VideoPlaybackKey: Hashable {
  let messageID: MessageID
  let attachmentID: String
  let relativePath: String

  var cacheKey: String {
    "\(messageID):\(attachmentID.utf8.count):\(attachmentID)\(relativePath)"
  }

  // Запоминает номер сообщения, вложение и путь. Если в той же строке поменялся исходник,
  // сохранённое состояние старого ролика уже не подходит.
  init(messageID: MessageID, attachment: Attachment) {
    self.messageID = messageID
    attachmentID = attachment.id
    relativePath = attachment.relativePath
  }
}
