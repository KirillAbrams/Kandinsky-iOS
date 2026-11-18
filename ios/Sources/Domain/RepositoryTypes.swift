import Foundation
enum RepoError: Error, Equatable, Sendable {
  case invalidInput, notFound, storageFull, io, corrupt, cancelled
}
enum PageDirection: Sendable { case older, newer, around }
struct PageRequest: Sendable {
  let chatID: ChatID
  var anchor: OrderKey? = nil
  var direction: PageDirection = .older
  var limit: Int = 128
  var visualOnly: Bool = false
}
struct HistoryPage: Sendable {
  let rows: [Message]
  let before: OrderKey?
  let after: OrderKey?
}
enum RepoFault: Sendable {
  case beforeCommit, afterCommitBeforeReply, beforeRename, afterRename, storageFull
}
final class RepositoryFaults: @unchecked Sendable {
  private let lock = NSLock()
  private var next: RepoFault?
  func arm(_ fault: RepoFault) {
    lock.lock()
    next = fault
    lock.unlock()
  }
  /// Возвращает признак срабатывания так, чтобы один и тот же назначенный отказ нельзя было применить
  /// дважды.
  func consume(_ fault: RepoFault) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard next == fault else { return false }
    next = nil
    return true
  }
}
