import Foundation

@MainActor final class NetworkUIBatch {
  private var pending: [ChatID: MessageDelta] = [:]
  private var flush: DispatchWorkItem?
  var deliver: (([MessageDelta]) -> Void)?
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
  /// После закрытия прежняя отложенная порция больше не должна обновлять представление.
  func close() {
    flush?.cancel()
    flush = nil
    pending = [:]
    deliver = nil
  }
}
