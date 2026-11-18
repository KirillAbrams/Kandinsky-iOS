// Реализует копирование и удаление строки из открытого чата айфона. Сначала проверяет сообщение
// через хранилище нужной истории.

import UIKit
@MainActor final class MessageActions {
  private let chatID: ChatID
  private let repository: ChatRepository
  private let state: ConversationState
  private let copyText: (String) -> Void
  var onDelta: ((MessageDelta) -> Void)?
  // Принимает чат, хранилище и действие копирования. Системный буфер можно заменить в тесте,
  // сохранив обычное чтение сообщения.
  init(
    chatID: ChatID, repository: ChatRepository, state: ConversationState,
    copyText: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }
  ) {
    self.chatID = chatID
    self.repository = repository
    self.state = state
    self.copyText = copyText
  }
  // Ищет номер в индексе выбранного чата и читает порцию вокруг него. Ошибка отсутствия не даст
  // действию перейти на строку из другой истории.
  private func message(_ id: MessageID) async throws -> Message {
    let index = try await repository.index(chatID: chatID)
    guard let key = index.first(where: { $0.messageID == id })?.order else {
      throw RepoError.notFound
    }
    let page = try await repository.history(
      PageRequest(chatID: chatID, anchor: key, direction: .around))
    guard let row = page.rows.first(where: { $0.id == id }) else { throw RepoError.notFound }
    return row
  }
  // Копирует текст сообщения или подпись к файлу, если текста нет. Пользователь получает то, что
  // видел у выбранной строки.
  func copy(id: MessageID) async throws -> String {
    let m = try await message(id)
    let value = m.text.isEmpty ? m.caption : m.text
    copyText(value)
    return value
  }
  // Удаляет найденную строку и сбрасывает ответ на неё в черновике при необходимости. Затем
  // отправляет изменения для обновления текущего экрана.
  @discardableResult func delete(id: MessageID) async throws -> MessageDelta {
    _ = try await message(id)
    let delta = try await repository.delete(messageID: id)
    if state.draft.replyToID == id {
      var value = state.draft
      value.replyToID = nil
      state.editDraft(value)
      try await state.flush()
    }
    onDelta?(delta)
    return delta
  }
}
