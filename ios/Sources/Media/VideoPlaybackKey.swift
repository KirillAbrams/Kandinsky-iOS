import Foundation

struct VideoPlaybackKey: Hashable {
  let messageID: MessageID
  let attachmentID: String
  let relativePath: String

  var cacheKey: String {
    "\(messageID):\(attachmentID.utf8.count):\(attachmentID)\(relativePath)"
  }

  init(messageID: MessageID, attachment: Attachment) {
    self.messageID = messageID
    attachmentID = attachment.id
    relativePath = attachment.relativePath
  }
}
