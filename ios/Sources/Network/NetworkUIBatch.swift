// Собирает пришедшие почти одновременно правки списка сообщений и передаёт их экрану одной
// порцией. Это уменьшает число обновлений при чтении и догрузке истории.

import Foundation

@MainActor final class NetworkUIBatch {
  private var pending: [ChatID: MessageDelta] = [:]
  private var flush: DispatchWorkItem?
  var deliver: (([MessageDelta]) -> Void)?
  // Для каждого чата объединяет новые версии и удаления по номерам строк. Назначает одну
  // доставку примерно через один кадр вместо пересчёта экрана после каждого отдельного ответа.
  func offer(_ deltas: [MessageDelta]) {
    for delta in deltas {
      guard let prior = pending[delta.chat.id] else {
        pending[delta.chat.id] = delta
        continue
      }
      var rows = Dictionary(
        (prior.inserted + prior.updated).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
      var removed = Set(prior.removedIDs + delta.removedIDs)
      for row in delta.inserted + delta.updated {
        removed.remove(row.id)
        rows[row.id] = row
      }
      for id in delta.removedIDs { rows.removeValue(forKey: id) }
      pending[delta.chat.id] = MessageDelta(
        updated: Array(rows.values), removedIDs: Array(removed), chat: delta.chat, reason: .sync)
    }
    guard flush == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.flush = nil
      let values = Array(self.pending.values)
      self.pending = [:]
      if !values.isEmpty { self.deliver?(values) }
    }
    flush = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
  }
  /// Отменяет запланированную доставку, очищает порцию и убирает получателя.
  /// Опоздавшее обновление не должно попасть в закрытый экран.
  func close() {
    flush?.cancel()
    flush = nil
    pending = [:]
    deliver = nil
  }
}
