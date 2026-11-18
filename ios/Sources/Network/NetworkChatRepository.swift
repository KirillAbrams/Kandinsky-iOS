import Foundation

final class NetworkChatRepository: ChatRepository, @unchecked Sendable {
  let local: SQLiteChatRepository
  let wake: @Sendable () -> Void

  init(local: SQLiteChatRepository, wake: @escaping @Sendable () -> Void) {
    self.local = local
    self.wake = wake
  }

  // Будим очередь после записи в SQLite. Тогда отправка переживёт потерю связи.
  func send(_ command: SendCommand) async throws -> MessageDelta {
    let delta = try await local.send(command)
    wake()
    return delta
  }

  func delete(messageID: MessageID) async throws -> MessageDelta {
    let delta = try await local.delete(messageID: messageID)
    wake()
    return delta
  }

  func markRead(chatID: ChatID) async throws { try await local.markRead(chatID: chatID) }

  func chats(matching query: String) async throws -> [ChatSummary] {
    let rows = try await local.chats(matching: query)
    return try await local.store.perform { db in
      try rows.map { try ChatServerState.decorate(db, $0) }.filter { !$0.hidden }
    }
  }

  func history(_ request: PageRequest) async throws -> HistoryPage {
    try await local.history(
      request, locations: { db, ids in try NetworkStore.attachmentLocations(db, ids) })
  }

  func index(chatID: ChatID) async throws -> [IndexedRow] { try await local.index(chatID: chatID) }

  func search(chatID: ChatID, text: String, before: OrderKey?) async throws -> [MessageID] {
    try await local.search(chatID: chatID, text: text, before: before)
  }

  func saveDraft(chatID: ChatID, draft: Draft) async throws {
    try await local.saveDraft(chatID: chatID, draft: draft)
  }

  func draft(chatID: ChatID) async throws -> Draft { try await local.draft(chatID: chatID) }

  func savePosition(chatID: ChatID, anchor: ReadingAnchor) async throws {
    try await local.savePosition(chatID: chatID, anchor: anchor)
  }

  func position(chatID: ChatID) async throws -> ReadingAnchor? {
    try await local.position(chatID: chatID)
  }
}
