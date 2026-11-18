// Здесь собраны параметры чтения истории, её границы и причины отказа хранилища.
// Проверки могут заранее назначить сбой на нужном шаге, чтобы проверить поведение при потере ответа.

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
  // Записывает следующий назначенный сбой под блокировкой, чтобы параллельная проверка
  // не прочитала значение посреди замены.
  func arm(_ fault: RepoFault) {
    lock.lock()
    next = fault
    lock.unlock()
  }
  /// Сравнивает текущий шаг с назначенным сбоем и сразу снимает совпавшую отметку.
  /// Следующий повтор сможет завершиться без того же искусственного отказа.
  func consume(_ fault: RepoFault) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard next == fault else { return false }
    next = nil
    return true
  }
}
