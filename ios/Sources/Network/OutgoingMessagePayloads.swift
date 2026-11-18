import Foundation

extension NetworkSync {
  func prepare(_ commands: [SendCommand]) async throws -> [[String: Any]] {
    let snapshot = try await store.perform {
      db -> (uploads: [String: (String, String?)], replies: [Int64: Int64]) in
      var uploads: [String: (String, String?)] = [:]
      var replies: [Int64: Int64] = [:]
      for row in try db.rows("SELECT attachmentID,blobID,previewBlobID FROM net_uploads") {
        uploads[row["attachmentID"]!.string] = (
          row["blobID"]!.string,
          row["previewBlobID"].flatMap {
            if case .text(let s) = $0 { return s }
            return nil
          }
        )
      }
      for command in commands {
        if let reply = command.replyToID,
          let server = try db.rows(
            "SELECT serverID FROM net_messages WHERE localID=?", [.integer(reply)]
          ).first?["serverID"]?.optionalInt
        {
          replies[reply] = server
        }
      }
      return (uploads, replies)
    }
    let root = store.root
    let api = self.api
    let messages = try await Self.encodeMessagesOffMain(
      commands, snapshot: snapshot, root: root, api: api)
    try await store.perform { db in
      try db.transaction {
        for message in messages {
          for attachment in message["attachments"] as? [[String: Any]] ?? [] {
            try db.execute(
              "INSERT OR REPLACE INTO net_uploads(attachmentID,blobID,previewBlobID) VALUES(?,?,?)",
              [
                .text(attachment["id"] as! String), .text(attachment["blobId"] as! String),
                (attachment["previewBlobId"] as? String).map(SQLValue.text) ?? .null,
              ])
          }
        }
      }
    }
    return messages
  }
  nonisolated private static func encodeMessagesOffMain(
    _ commands: [SendCommand],
    snapshot: (uploads: [String: (String, String?)], replies: [Int64: Int64]), root: URL,
    api: NetworkAPI
  ) async throws -> [[String: Any]] {
    var messages: [[String: Any]] = []
    for command in commands {
      if let reply = command.replyToID, snapshot.replies[reply] == nil { continue }
      var attachments: [[String: Any]] = []
      for attachment in command.attachments {
        let blob: String
        let preview: String?
        if let saved = snapshot.uploads[attachment.id] {
          blob = saved.0
          preview = saved.1
        } else {
          let result = try await api.upload(
            file: root.appendingPathComponent("media/" + attachment.relativePath),
            mime: attachment.mime,
            id: attachment.id.lowercased(),
            studioSource: command.generationOptions != nil
              && (attachment.mime.hasPrefix("image/") || attachment.mime == "video/mp4"),
            chat: command.chatID)
          blob = try result.string("blobId")
          preview = try await NetworkPreview.upload(
            root: root, attachment: attachment, api: api, parent: blob)
        }
        attachments.append([
          "id": attachment.id, "blobId": blob, "previewBlobId": preview as Any? ?? NSNull(),
          "mime": attachment.mime,
          "byteSize": attachment.byteSize, "rawWidth": attachment.rawWidth,
          "rawHeight": attachment.rawHeight,
          "orientation": attachment.orientation,
          "durationMs": attachment.durationMs as Any? ?? NSNull(),
          "thumbnailKey": attachment.thumbnailKey,
          "tinyPreview": attachment.tinyPreview as Any? ?? NSNull(),
          "waveform": attachment.waveform as Any? ?? NSNull(),
        ])
      }
      var message: [String: Any] = [
        "clientId": command.operationID.lowercased(), "chatId": command.chatID,
        "kind": command.kind.rawValue, "text": command.text, "caption": command.caption,
        "replyToId": command.replyToID.flatMap { snapshot.replies[$0] } as Any? ?? NSNull(),
        "attachments": attachments,
      ]
      if let options = command.generationOptions {
        message["generationOptions"] = options.wire
      }
      messages.append(message)
    }
    return messages
  }
}
