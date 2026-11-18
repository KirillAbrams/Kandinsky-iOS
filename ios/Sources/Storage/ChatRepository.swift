import Foundation
protocol ChatRepository: Sendable {
  func markRead(chatID: ChatID) async throws
  func chats(matching query: String) async throws -> [ChatSummary]
  func history(_ request: PageRequest) async throws -> HistoryPage
  func index(chatID: ChatID) async throws -> [IndexedRow]
  func send(_ command: SendCommand) async throws -> MessageDelta
  func delete(messageID: MessageID) async throws -> MessageDelta
  func search(chatID: ChatID, text: String, before: OrderKey?) async throws -> [MessageID]
  func saveDraft(chatID: ChatID, draft: Draft) async throws
  /// Возвращаемые данные позволяют продолжить ввод и известную незавершённую отправку после закрытия
  /// экрана.
  func draft(chatID: ChatID) async throws -> Draft
  /// Опора хранит сообщение, положение внутри строки и связь с концом истории, чтобы возвращение не
  /// сбрасывало прокрутку.
  func savePosition(chatID: ChatID, anchor: ReadingAnchor) async throws
  func position(chatID: ChatID) async throws -> ReadingAnchor?
}
