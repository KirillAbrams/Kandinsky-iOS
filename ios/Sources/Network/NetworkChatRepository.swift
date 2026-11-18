// Даёт экрану единый доступ к местной истории и очереди сетевых команд. Запись происходит на
// телефоне до отправки, а чтение дополняется сохранённым состоянием сервера.

import Foundation

final class NetworkChatRepository: ChatRepository, @unchecked Sendable {
  let local: SQLiteChatRepository
  let wake: @Sendable () -> Void

  // Запоминает местное хранилище и способ разбудить обмен. Экран может пользоваться одним
  // хранилищем, не управляя соединением напрямую.
  init(local: SQLiteChatRepository, wake: @escaping @Sendable () -> Void) {
    self.local = local
    self.wake = wake
  }

  // Сначала сохраняет сообщение, затем будит очередь. Если связь пропадёт после записи, команда
  // останется на диске для повтора.
  func send(_ command: SendCommand) async throws -> MessageDelta {
    let delta = try await local.send(command)
    wake()
    return delta
  }

  // Сохраняет местное удаление и запускает проверку очереди. Сбой сети не возвращает строку
  // только потому, что команда ещё не ушла.
  func delete(messageID: MessageID) async throws -> MessageDelta {
    let delta = try await local.delete(messageID: messageID)
    wake()
    return delta
  }

  // Записывает прочитанную границу местным путём. Отметка остаётся доступной при новом открытии
  // без ожидания сети.
  func markRead(chatID: ChatID) async throws { try await local.markRead(chatID: chatID) }

  // Читает совпавшие карточки, дополняет их серверными признаками и убирает скрытые. Поиск по
  // местному названию не должен показывать удалённую или скрытую карточку.
  func chats(matching query: String) async throws -> [ChatSummary] {
    let rows = try await local.chats(matching: query)
    return try await local.store.perform { db in
      try rows.map { try ChatServerState.decorate(db, $0) }.filter { !$0.hidden }
    }
  }

  // Передаёт границу чтения местному хранилищу и добавляет адреса серверных вложений. Так
  // сохранённая строка сохраняет путь к возможному скачиванию.
  func history(_ request: PageRequest) async throws -> HistoryPage {
    try await local.history(
      request, locations: { db, ids in try NetworkStore.attachmentLocations(db, ids) })
  }

  // Читает компактный указатель строк чата из базы. Экран может ориентироваться в истории без
  // загрузки всех сообщений.
  func index(chatID: ChatID) async throws -> [IndexedRow] { try await local.index(chatID: chatID) }

  // Ищет текст в выбранном чате до переданной границы. Повтор поиска может продолжить с нужного
  // места вместо чтения всех совпадений заново.
  func search(chatID: ChatID, text: String, before: OrderKey?) async throws -> [MessageID] {
    try await local.search(chatID: chatID, text: text, before: before)
  }

  // Записывает ввод для выбранного чата. После ухода с экрана черновик остаётся привязан к этому
  // же чату.
  func saveDraft(chatID: ChatID, draft: Draft) async throws {
    try await local.saveDraft(chatID: chatID, draft: draft)
  }

  // Читает сохранённый ввод чата. Экран может восстановить его, не загружая серверную историю.
  func draft(chatID: ChatID) async throws -> Draft { try await local.draft(chatID: chatID) }

  // Запоминает опорную строку чтения для чата. Перезапуск не должен сбрасывать пользователя к
  // концу истории.
  func savePosition(chatID: ChatID, anchor: ReadingAnchor) async throws {
    try await local.savePosition(chatID: chatID, anchor: anchor)
  }

  // Читает прежнюю опору или сообщает, что её нет. Экран может различить возвращение к чтению и
  // первое открытие.
  func position(chatID: ChatID) async throws -> ReadingAnchor? {
    try await local.position(chatID: chatID)
  }
}
