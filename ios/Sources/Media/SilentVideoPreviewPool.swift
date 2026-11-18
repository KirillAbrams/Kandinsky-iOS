// Ограничивает число тихих роликов ленты. Видимые получают место первыми, ближайший невидимый
// может подготовиться при наличии свободного места.

import Foundation

/// Ближайшие ролики остаются на паузе. Новое видимое видео вытесняет самое давнее невидимое.
@MainActor final class SilentVideoPreviewPool {
  private var entries: [VideoPlaybackKey: SilentVideoPreview] = [:]
  private var order: [VideoPlaybackKey] = []
  private var visible = Set<VideoPlaybackKey>()
  private var preparing: VideoPlaybackKey?
  private var triedPreparation = false
  private var limit = 2

  // Принимает ключи видимых роликов и общий предел, отмечает новую видимость и убирает закрытые
  // записи. Если мест стало меньше, вытесняет невидимые.
  func beginFrame(
    visibleKeys: [VideoPlaybackKey], limit: Int, preparing: VideoPlaybackKey? = nil
  ) {
    if self.preparing != preparing {
      self.preparing = preparing
      triedPreparation = false
    }
    self.limit = min(4, max(0, limit))
    visible = Set(visibleKeys.prefix(self.limit))
    for (key, owner) in Array(entries) {
      if owner.closed {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
      } else {
        owner.setVisible(visible.contains(key))
      }
    }
    while entries.count > self.limit && evictPaused() {}
  }

  // Возвращает живой показ нужного ролика или создаёт его при свободном месте. Для одного
  // ближайшего невидимого ролика делает только одну попытку подготовки.
  func preview(_ key: VideoPlaybackKey, create: () -> SilentVideoPreview) -> SilentVideoPreview? {
    let onScreen = visible.contains(key)
    guard onScreen || key == preparing && visible.count < limit else { return nil }
    if let owner = entries[key], !owner.closed {
      if onScreen {
        order.removeAll { $0 == key }
        order.append(key)
      }
      owner.setVisible(onScreen)
      return owner
    }
    if !onScreen && triedPreparation { return nil }
    while entries.count >= limit {
      guard evictPaused() else { return nil }
    }
    if !onScreen { triedPreparation = true }
    let owner = create()
    entries[key] = owner
    order.removeAll { $0 == key }
    order.append(key)
    owner.setVisible(onScreen)
    return owner
  }

  // Освобождает самый давний невидимый ролик. Видимый кадр не должен исчезнуть только потому, что
  // появился новый запрос.
  @discardableResult private func evictPaused() -> Bool {
    guard let key = order.first(where: { !visible.contains($0) }) else { return false }
    order.removeAll { $0 == key }
    entries.removeValue(forKey: key)?.close()
    return true
  }

  // Обнуляет список и закрывает всех владельцев роликов. После ухода из ленты не остаётся
  // фонового проигрывания.
  func clear() {
    let old = Array(entries.values)
    entries.removeAll()
    order.removeAll()
    visible.removeAll()
    preparing = nil
    triedPreparation = false
    old.forEach { $0.close() }
  }
}
