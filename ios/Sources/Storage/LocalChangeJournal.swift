import Foundation

protocol LocalChangeJournal: Sendable {
  /// Вызывается внутри той же операции базы, что и создание видимого сообщения, поэтому очередь и история
  /// не расходятся.
  func appended(_ database: SQLiteConnection, command: SendCommand, localID: MessageID) throws
  /// Сохранение намерения выполняется вместе с местным удалением, чтобы оно не потерялось после закрытия
  /// приложения.
  func deleting(_ database: SQLiteConnection, message: Message) throws
  func read(_ database: SQLiteConnection, chatID: ChatID) throws
}
