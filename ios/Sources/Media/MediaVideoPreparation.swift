import Foundation

/// Только ближайший ролик читает части файла; видимая передача может прервать эту подготовку.
@MainActor final class MediaVideoPreparation {
  private final class Entry {
    let key: String
    let work: (MediaCancellation) throws -> Void
    var owners = Set<UUID>()
    var generation = 0
    var done = false
    var request: MediaCancellation?
    var fetch: MediaCancellation?
    init(_ key: String, _ work: @escaping (MediaCancellation) throws -> Void) {
      self.key = key
      self.work = work
    }
  }
  private let queue = MediaDecodeQueue(maximumWorkers: 1, maximumPending: 8)
  private var entries: [Entry] = []
  private var active: Entry?
  private var paused = false
  private var closed = false

  func acquire(_ key: String, work: @escaping (MediaCancellation) throws -> Void)
    -> MediaCancellation?
  {
    guard !closed else { return nil }
    let entry: Entry
    if let existing = entries.first(where: { $0.key == key }) {
      entry = existing
    } else {
      guard entries.count < 8 else { return nil }
      entry = Entry(key, work)
      entries.append(entry)
    }
    let owner = UUID()
    let token = MediaCancellation()
    entry.owners.insert(owner)
    token.onCancel { [weak self, weak entry] in
      DispatchQueue.main.async {
        guard let self, let entry else { return }
        entry.owners.remove(owner)
        if entry.owners.isEmpty {
          self.entries.removeAll { $0 === entry }
          self.stop(entry)
        }
        self.startNext()
      }
    }
    startNext()
    return token
  }
  func setPaused(_ value: Bool) {
    paused = value
    if value, let active { stop(active) }
    if !value { startNext() }
  }
  private func stop(_ entry: Entry) {
    entry.generation += 1
    entry.fetch?.cancel()
    entry.request?.cancel()
    entry.fetch = nil
    entry.request = nil
    if active === entry { active = nil }
  }
  private func startNext() {
    guard !closed, !paused, active == nil, let entry = entries.first(where: { !$0.done }) else {
      return
    }
    active = entry
    entry.generation += 1
    let generation = entry.generation
    let fetch = MediaCancellation()
    entry.fetch = fetch
    entry.request = queue.submit(
      work: { try entry.work(fetch) }, dispose: { _ in },
      completion: { [weak self] _ in
        guard let self, entry.generation == generation else { return }
        _ = fetch.finish()
        entry.done = true
        entry.request = nil
        entry.fetch = nil
        self.active = nil
        self.startNext()
      })
  }
  func clear() {
    let old = entries
    entries.removeAll()
    for entry in old { stop(entry) }
  }
  func close() {
    closed = true
    clear()
    queue.close()
  }
}
