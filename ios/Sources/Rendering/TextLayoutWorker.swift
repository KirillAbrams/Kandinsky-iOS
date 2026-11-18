import Foundation
final class TextLayoutCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  /// Очередь и вычисление читают этот признак, чтобы не отдавать устаревший результат закрытому или
  /// изменившемуся экрану.
  func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
final class TextLayoutWorker: @unchecked Sendable {
  private struct Job {
    let message: Message
    let key: TextLayoutKey
    let ticket: Int
    let token: TextLayoutCancellation
    let completion: @Sendable (Int, PreparedText?) -> Void
  }
  private let coordinator = DispatchQueue(label: "dev.kirill.kandinsky.text.admission")
  private let workers = DispatchQueue(
    label: "dev.kirill.kandinsky.text.layout", qos: .userInitiated, attributes: .concurrent)
  private var pending: [Job] = []
  private var visibleKeys: Set<TextLayoutKey> = []

  func prioritizeVisible(_ keys: Set<TextLayoutKey>) {
    coordinator.async {
      guard self.visibleKeys != keys else { return }
      self.visibleKeys = keys
      // После смены направления видимая строка обходит прежнюю предварительную разметку.
      let visible = self.pending.filter { keys.contains($0.key) }
      self.pending.removeAll { keys.contains($0.key) }
      self.pending.insert(contentsOf: visible, at: 0)
    }
  }
  private var active = 0
  private var closed = false
  @discardableResult func prepare(
    message: Message, key: TextLayoutKey, ticket: Int,
    completion: @escaping @Sendable (Int, PreparedText?) -> Void
  ) -> TextLayoutCancellation {
    let token = TextLayoutCancellation(),
      job = Job(message: message, key: key, ticket: ticket, token: token, completion: completion)
    coordinator.sync {
      guard !self.closed else {
        DispatchQueue.main.async { completion(ticket, nil) }
        return
      }
      self.pending.removeAll { job in
        if job.token.isCancelled {
          DispatchQueue.main.async { job.completion(job.ticket, nil) }
          return true
        }
        return false
      }
      let visible = self.visibleKeys.contains(key)
      if self.pending.count >= 32 {
        guard visible, let farthest = self.pending.lastIndex(where: {
          !self.visibleKeys.contains($0.key)
        }) else {
          token.cancel()
          DispatchQueue.main.async { completion(ticket, nil) }
          return
        }
        let old = self.pending.remove(at: farthest)
        old.token.cancel()
        DispatchQueue.main.async { old.completion(old.ticket, nil) }
      }
      if visible, let firstOffscreen = self.pending.firstIndex(where: {
        !self.visibleKeys.contains($0.key)
      }) {
        self.pending.insert(job, at: firstOffscreen)
      } else {
        self.pending.append(job)
      }
      self.drain()
    }
    return token
  }
  private func drain() {
    while active < 2 && !pending.isEmpty && !closed {
      let job = pending.removeFirst()
      active += 1
      workers.async {
        let resource =
          job.token.isCancelled
          ? nil
          : autoreleasepool {
            PreparedText(message: job.message, key: job.key, isCancelled: { job.token.isCancelled })
          }
        self.coordinator.async {
          self.active -= 1
          let cancelled = self.closed || job.token.isCancelled
          DispatchQueue.main.async {
            if cancelled || job.token.isCancelled {
              resource?.close()
              job.completion(job.ticket, nil)
            } else {
              job.completion(job.ticket, resource)
            }
          }
          self.drain()
        }
      }
    }
  }
  func close() {
    coordinator.async {
      self.closed = true
      for job in self.pending {
        job.token.cancel()
        DispatchQueue.main.async { job.completion(job.ticket, nil) }
      }
      self.pending.removeAll()
    }
  }
}
@MainActor final class FragmentLayoutCache {
  private var values: [TextLayoutKey: PreparedText] = [:], order: [TextLayoutKey] = []
  private(set) var bytes = 0
  private(set) var revision = 0
  var limit = 32 * 1024 * 1024
  /// Успешное чтение делает запись недавно использованной, чтобы при следующем вытеснении сначала ушли более
  /// старые обращения.
  func value(_ key: TextLayoutKey) -> PreparedText? {
    if let v = values[key] {
      order.removeAll { $0 == key }
      order.append(key)
      return v
    }
    return nil
  }
  func insert(_ value: PreparedText) {
    let key = value.key
    revision &+= 1
    if let old = values.removeValue(forKey: key) {
      bytes -= old.byteCost
      order.removeAll { $0 == key }
    }
    guard value.byteCost <= limit else { return }
    values[key] = value
    order.append(key)
    bytes += value.byteCost
    trim()
  }
  func trim() {
    let previousCount = values.count
    while bytes > limit || values.count > 256 {
      guard !order.isEmpty else { break }
      let key = order.removeFirst()
      if let old = values.removeValue(forKey: key) { bytes -= old.byteCost }
    }
    if values.count != previousCount { revision &+= 1 }
  }
  func clear() {
    revision &+= 1
    values.removeAll()
    order.removeAll()
    bytes = 0
  }
}
