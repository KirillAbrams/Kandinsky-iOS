// Готовит изображения для близких строк и части ближайшего видео. Готовые большие кадры остаются
// в хранилище, а уходящие из области запросы отменяются.

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
    // Запоминает путь файла для одной ожидаемой строки. Он помогает отличить ближайший ролик от
    // остальных.
    init(_ relativePath: String) { self.relativePath = relativePath }
    // Отменяет обычную и малую миниатюры и подготовку видео, затем закрывает удерживаемый малый
    // кадр. Ушедшая строка освобождает свою работу.
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

  // Складывает путь, размер и выбор оригинала в ключ. Одна фотография разных размеров не должна
  // выдавать чужую копию.
  private func identity(_ attachment: Attachment, _ key: ThumbnailKey) -> String {
    attachment.relativePath + "@\(key.maxPixel):\(key.studioOriginal)"
  }

  // Возвращает удержание готовой миниатюры, а при её отсутствии маленький сохранённый кадр. Не
  // начинает сетевой запрос в момент показа.
  func preview(_ item: Item, store: MediaStore) -> PreparedImage? {
    let attachment = item.attachment
    let key = store.studioPhotoKey(attachment) ?? ThumbnailKey(maxPixel: item.maxPixel)
    guard let entry = entries[identity(attachment, key)] else { return nil }
    return store.cachedThumbnail(attachment: attachment, key: key) ?? entry.tiny?.retained()
  }

  // Берёт до двенадцати ближайших вложений, убирает старые и не дублирует одинаковые.
  // Предварительно готовит только ближайшее видео и оставляет большие рисунки в вытесняемом
  // хранилище.
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

  // Закрывает все записи подготовки и очищает список. После закрытия страницы не остаётся
  // ожидающих загрузок для соседних строк.
  func clear() {
    entries.values.forEach { $0.close() }
    entries.removeAll()
  }
}
