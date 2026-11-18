// Считает получателей общей загрузки. Пока результат кому-то нужен, снятие одного получателя не
// мешает другим.

import Foundation

/// Последний получатель останавливает передачу сразу, даже если очередь экрана занята.
final class MediaRequestOwners: @unchecked Sendable {
  let cancellation = MediaCancellation()
  private let gate = NSLock()
  private var owners = Set<UUID>()
  private var closed = false

  // Добавляет получателя под блокировкой и отказывает, если загрузка уже закрыта. Иначе экран мог
  // бы подписаться на передачу, которую никто не закончит.
  func insert(_ owner: UUID) -> Bool {
    gate.lock()
    defer { gate.unlock() }
    guard !closed else { return false }
    owners.insert(owner)
    return true
  }
  // Убирает указанного получателя и закрывает передачу, если он был последним. Отменяет после
  // снятия блокировки, чтобы вызов отмены мог выполнить свою очистку.
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
  // Закрывает вход для новых получателей, очищает список и сразу отменяет передачу. Это нужно,
  // при закрытии очереди.
  func close() {
    gate.lock()
    closed = true
    owners.removeAll()
    gate.unlock()
    cancellation.cancel()
  }
}
