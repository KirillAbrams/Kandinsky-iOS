// Хранит ограниченную часть фото и видео одного чата вокруг выбранного файла. Подгружает соседние
// страницы и сохраняет порядок вложений при обновлении истории.

import Foundation

struct MediaGalleryEntry: Equatable, Sendable {
  let messageID: MessageID, chatID: ChatID, order: OrderKey, kind: MessageKind
  let caption: String, savedAtMs: Int64, attachmentIndex: Int, attachment: Attachment,
    isIncoming: Bool
  // Держит постоянное имя результата или позицию обычного вложения внутри сообщения.
  var id: String {
    let part =
      attachment.id.hasPrefix("net-") && attachment.id.contains("-result-")
      ? attachment.id : String(attachmentIndex)
    return "\(messageID)/" + part
  }
  // По виду вложения выбирает проигрывание ролика, если файл относится к видео.
  var isVideo: Bool { attachment.mime.hasPrefix("video/") }
  // Сравнивает путь, вид, размер и поворот файла. Если эти свойства не изменились, экран может
  // оставить подготовленное изображение.
  func hasSameMedia(as other: Self) -> Bool {
    attachment.relativePath == other.attachment.relativePath
      && attachment.mime == other.attachment.mime
      && attachment.byteSize == other.attachment.byteSize
      && attachment.rawWidth == other.attachment.rawWidth
      && attachment.rawHeight == other.attachment.rawHeight
      && attachment.orientation == other.attachment.orientation
  }
  // Превращает сообщение в видимые файлы с порядком и подписью. Пропускает неподходящие виды,
  // чтобы голосовая или текстовая строка не стала пустой страницей.
  static func entries(_ row: Message) -> [Self] {
    guard [.photo, .video, .gif].contains(row.kind) else { return [] }
    return row.attachments.enumerated().compactMap { index, a in
      guard a.mime.hasPrefix("image/") || a.mime.hasPrefix("video/") else { return nil }
      return Self(
        messageID: row.id, chatID: row.chatID, order: row.order, kind: row.kind,
        caption: row.caption, savedAtMs: row.savedAtMs, attachmentIndex: index, attachment: a,
        isIncoming: row.direction == .incoming)
    }
  }
}

struct MediaGalleryWindow: Sendable {
  static let maximumEntries = 96
  let chatID: ChatID
  private(set) var entries: [MediaGalleryEntry]
  private var selectedID: String?
  private(set) var hasOlder = true, hasNewer = true
  // Ищет текущую позицию по имени, чтобы добавление ранней страницы не меняло выбор.
  var selectedIndex: Int? { entries.firstIndex { $0.id == selectedID } }
  // Возвращает текущий файл, когда его позиция ещё находится в окне.
  var selected: MediaGalleryEntry? { selectedIndex.map { entries[$0] } }
  // Отдаёт текущий файл и по одному соседу, чтобы подготовить ближайшие переходы.
  var neighbours: [MediaGalleryEntry] {
    guard let index = selectedIndex else { return [] }
    return Array(entries[max(0, index - 1)...min(entries.count - 1, index + 1)])
  }
  // Просит догрузку только у края, за которым есть продолжение.
  var needsPage: Bool {
    guard let index = selectedIndex else { return false }
    return index < 4 && hasOlder || entries.count - 1 - index < 4 && hasNewer
  }
  // Начинает просмотр с выбранного вложения сообщения или первого доступного файла. Сразу
  // ограничивает размер группы для большого альбома.
  init(seed: Message, attachmentIndex: Int = 0) {
    chatID = seed.chatID
    entries = MediaGalleryEntry.entries(seed)
    selectedID = entries.first { $0.attachmentIndex == attachmentIndex }?.id ?? entries.first?.id
    trim()
  }
  // Меняет текущий файл только если он находится в сохранённом окне. Отсутствующий номер не
  // сбрасывает прежний выбор.
  @discardableResult mutating func select(_ id: String) -> Bool {
    guard entries.contains(where: { $0.id == id }) else { return false }
    selectedID = id
    return true
  }
  // Отклоняет чужую историю, обновляет её границы и объединяет файлы по постоянным номерам.
  // Соседняя страница не дублирует уже видимые элементы.
  @discardableResult mutating func merge(_ page: HistoryPage) -> Bool {
    guard page.rows.allSatisfy({ $0.chatID == chatID }) else { return false }
    let incoming = page.rows.flatMap(MediaGalleryEntry.entries).sorted(by: Self.before)
    if incoming.isEmpty {
      hasOlder = false
      hasNewer = false
      return true
    }
    if entries.first == nil || incoming.first!.order <= entries.first!.order {
      hasOlder = page.before != nil
    }
    if entries.last == nil || incoming.last!.order >= entries.last!.order {
      hasNewer = page.after != nil
    }
    var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    for entry in incoming { byID[entry.id] = entry }
    entries = byID.values.sorted(by: Self.before)
    trim()
    return true
  }
  // Заменяет изменённые строки и убирает удалённые. Если текущего файла больше нет, выбирает
  // соседний по порядку, чтобы просмотр не показывал удалённое.
  mutating func apply(_ delta: MessageDelta) {
    guard delta.chat.id == chatID else { return }
    let previous = selected
    let changed = (delta.updated + delta.inserted).filter { $0.chatID == chatID }
    let removed = Set(delta.removedIDs + changed.map(\.id))
    var byID = Dictionary(
      uniqueKeysWithValues: entries.filter { !removed.contains($0.messageID) }.map { ($0.id, $0) })
    for row in changed { for entry in MediaGalleryEntry.entries(row) { byID[entry.id] = entry } }
    entries = byID.values.sorted(by: Self.before)
    if selectedIndex == nil {
      selectedID =
        entries.first { entry in previous.map { !Self.before(entry, $0) } ?? true }?.id
        ?? entries.last?.id
    }
    trim()
  }
  // Сравнивает порядок сообщения, а внутри него номер вложения. Так догрузка не переставляет
  // снимки одного альбома.
  private static func before(_ a: MediaGalleryEntry, _ b: MediaGalleryEntry) -> Bool {
    a.order == b.order ? a.attachmentIndex < b.attachmentIndex : a.order < b.order
  }
  // Оставляет ограниченное окно вокруг выбора, отмечая, можно ли снова запросить отброшенные
  // стороны. Длинный просмотр не удерживает всю историю в памяти.
  private mutating func trim() {
    guard entries.count > Self.maximumEntries else { return }
    let selected = selectedIndex ?? 0
    let lower = max(0, min(selected - Self.maximumEntries / 2, entries.count - Self.maximumEntries))
    let upper = min(entries.count, lower + Self.maximumEntries)
    if lower > 0 { hasOlder = true }
    if upper < entries.count { hasNewer = true }
    entries = Array(entries[lower..<upper])
  }
}
