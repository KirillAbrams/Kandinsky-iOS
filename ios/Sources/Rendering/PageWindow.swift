// Окно истории на айфоне держит до трёх небольших порций сообщений. Оно принимает ответы только
// для своего чата и свежего запроса, чтобы при быстрой прокрутке и закрытии не оставались чужие
// или старые строки.

import Foundation
@MainActor final class PageWindow {
  private let repository: ChatRepository?
  private(set) var generation = 1
  private(set) var chatID: ChatID
  private var pages: [[Message]] = []
  private var closed = false
  // Объединяем пересекающиеся порции по номеру, оставляя новую редакцию и порядок переписки.
  var loadedRows: [Message] {
    var map: [MessageID: Message] = [:]
    for page in pages {
      for row in page where (map[row.id]?.revision ?? -1) <= row.revision { map[row.id] = row }
    }
    return map.values.sorted { $0.order < $1.order }
  }
  // Считаем сообщения после объединения, чтобы пересечение порций не увеличило результат.
  var loadedCount: Int { loadedRows.count }
  // Привязываем окно к номеру переписки и при наличии к хранилищу. Окно без хранилища может
  // принять готовые строки при подготовке экрана.
  init(chatID: ChatID, repository: ChatRepository? = nil) {
    self.chatID = chatID
    self.repository = repository
  }
  // Присваиваем запросу новый номер, читаем историю и сравниваем этот номер после ожидания.
  // Закрытие или более свежий запрос лишают результат права менять окно.
  func request(_ request: PageRequest) async throws -> HistoryPage {
    guard !closed, request.chatID == chatID, let repository else { throw RepoError.cancelled }
    generation += 1
    let ticket = generation
    let page = try await repository.history(request)
    guard !closed, ticket == generation, !Task.isCancelled else { throw RepoError.cancelled }
    apply(page, chatID: request.chatID, generation: ticket)
    return page
  }
  // Принимаем только ограниченную порцию этого чата с текущим номером. Когда получена четвёртая,
  // освобождаем самую раннюю, чтобы память оставалась ограниченной.
  func apply(_ page: HistoryPage, chatID: ChatID, generation: Int) {
    guard !closed, self.chatID == chatID, self.generation == generation, page.rows.count <= 128,
      page.rows.allSatisfy({ $0.chatID == chatID })
    else { return }
    pages.append(page.rows)
    if pages.count > 3 { pages.removeFirst(pages.count - 3) }
  }
  // Во всех удерживаемых порциях заменяем старую редакцию сообщения более новой. Если строки ещё
  // нет в окне, это действие не расширяет его.
  func refreshKnownRow(_ message: Message) {
    for page in pages.indices {
      if let i = pages[page].firstIndex(where: {
        $0.id == message.id && $0.revision < message.revision
      }) {
        pages[page][i] = message
      }
    }
  }
  // Проверяем принадлежность, число и уникальность уже полученных строк. Сортируем и складываем
  // порциями, чтобы повторно открыть знакомый участок без нового чтения.
  func seedKnownRows(_ rows: [Message]) {
    guard !closed, rows.count <= 384, rows.allSatisfy({ $0.chatID == chatID }),
      Set(rows.map(\.id)).count == rows.count
    else { return }
    let ordered = rows.sorted { $0.order < $1.order }
    pages = stride(from: 0, to: ordered.count, by: 128).map {
      Array(ordered[$0..<min($0 + 128, ordered.count)])
    }
  }
  // Запрещаем новые запросы, увеличиваем номер и освобождаем строки. Позднее завершение старого
  // чтения уже не сможет наполнить окно.
  func close() {
    closed = true
    generation += 1
    pages.removeAll()
  }
}
