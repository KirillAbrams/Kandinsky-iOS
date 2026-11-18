import Foundation

/// У соседних сообщений остаётся вытесняемый кэш, а не скрытый владелец полного рисунка.
@MainActor final class MediaImagePrefetch {
  struct Item {
    let attachment: Attachment
    var maxPixel: Int = 1024
  }

  static let albumMaxPixel = 512
  private final class Entry {
    let relativePath: String
    var request: MediaCancellation?, tinyRequest: MediaCancellation?, video: MediaCancellation?, tiny: PreparedImage?
    var closed = false
    init(_ relativePath: String) { self.relativePath = relativePath }
    func close() {
      closed = true
      request?.cancel()
      tinyRequest?.cancel()
      video?.cancel()
      tiny?.close()
      tiny = nil
    }
  }
  private var entries: [String: Entry] = [:]

  private func identity(_ attachment: Attachment, _ key: ThumbnailKey) -> String {
    attachment.relativePath + "@\(key.maxPixel):\(key.studioOriginal)"
  }

  func preview(_ item: Item, store: MediaStore) -> PreparedImage? {
    let attachment = item.attachment
    let key = store.studioPhotoKey(attachment) ?? ThumbnailKey(maxPixel: item.maxPixel)
    guard let entry = entries[identity(attachment, key)] else { return nil }
    return store.cachedThumbnail(attachment: attachment, key: key) ?? entry.tiny?.retained()
  }

  func update(_ items: [Item], store: MediaStore) {
    let selected = items.prefix(12).map { item in
      let key = store.studioPhotoKey(item.attachment) ?? ThumbnailKey(maxPixel: item.maxPixel)
      return (attachment: item.attachment, key: key, identity: identity(item.attachment, key))
    }
    let identities = Set(selected.map(\.identity))
    for identity in Array(entries.keys) where !identities.contains(identity) {
      entries.removeValue(forKey: identity)?.close()
    }
    let videoPath = selected.first(where: { $0.attachment.mime.hasPrefix("video/") })?.attachment.relativePath
    for entry in entries.values where entry.relativePath != videoPath {
      entry.video?.cancel()
      entry.video = nil
    }
    var wanted = Set<String>()
    for (attachment, key, identity) in selected {
      guard wanted.insert(identity).inserted else { continue }
      if let entry = entries[identity], attachment.relativePath == videoPath, entry.video == nil {
        entry.video = store.prepareStudioVideo(attachment)
      }
      if entries[identity] == nil {
        let entry = Entry(attachment.relativePath)
        entries[identity] = entry
        if attachment.relativePath == videoPath { entry.video = store.prepareStudioVideo(attachment) }
        if let cached = store.cachedThumbnail(attachment: attachment, key: key) {
          cached.close()
          continue
        }
        entry.tinyRequest = store.tinyPreview(attachment) { [weak entry] result in
          if case let .success(frame) = result {
            if let entry, !entry.closed { entry.tiny = frame } else { frame.close() }
          }
        }
        entry.request = store.thumbnail(
          attachment: attachment, key: key, ticket: 0, priority: 0
        ) { _, result in
          if case let .success(frame) = result { frame.close() }
        }
      }
    }
  }

  func clear() {
    entries.values.forEach { $0.close() }
    entries.removeAll()
  }
}
