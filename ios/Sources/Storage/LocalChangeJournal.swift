// Связывает местную запись в чате с очередью действий для сервера. Оба изменения выполняются
// внутри одной операции базы.

import Foundation

protocol LocalChangeJournal: Sendable {
  // Записывает команду отправки рядом с только что добавленным сообщением. Если запись очереди не
  // удалась, вместе с ней отменяется появление сообщения.
  func appended(_ database: SQLiteConnection, command: SendCommand, localID: MessageID) throws
  // Запоминает намерение удалить сообщение тогда же, когда оно удаляется на телефоне. После
  // перезапуска действие ещё можно передать серверу.
  func deleting(_ database: SQLiteConnection, message: Message) throws
  // Сохраняет команду отметки о прочтении вместе с местным изменением. Без неё сервер и второе
  // устройство могли бы сохранить прежний счётчик.
  func read(_ database: SQLiteConnection, chatID: ChatID) throws
}
