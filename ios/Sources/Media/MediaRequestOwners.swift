import Foundation

/// Последний получатель останавливает передачу сразу, даже если очередь экрана занята.
final class MediaRequestOwners: @unchecked Sendable {
  let cancellation = MediaCancellation()
  private let gate = NSLock()
  private var owners = Set<UUID>()
  private var closed = false

  func insert(_ owner: UUID) -> Bool {
    gate.lock()
    defer { gate.unlock() }
    guard !closed else { return false }
    owners.insert(owner)
    return true
  }
  func remove(_ owner: UUID) {
    gate.lock()
    let shouldCancel = owners.remove(owner) != nil && owners.isEmpty
    if shouldCancel { closed = true }
    gate.unlock()
    if shouldCancel { cancellation.cancel() }
  }
  var isClosed: Bool {
    gate.lock()
    defer { gate.unlock() }
    return closed
  }
  func close() {
    gate.lock()
    closed = true
    owners.removeAll()
    gate.unlock()
    cancellation.cancel()
  }
}
