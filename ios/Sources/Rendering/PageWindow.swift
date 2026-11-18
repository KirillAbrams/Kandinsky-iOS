import Foundation
@MainActor final class PageWindow {
  private let repository: ChatRepository?
  private(set) var generation = 1
  private(set) var chatID: ChatID
  private var pages: [[Message]] = []
  private var closed = false
  var loadedRows: [Message] {
    var map: [MessageID: Message] = [:]
    for page in pages {
      for row in page where (map[row.id]?.revision ?? -1) <= row.revision { map[row.id] = row }
    }
    return map.values.sorted { $0.order < $1.order }
  }
  var loadedCount: Int { loadedRows.count }
  init(chatID: ChatID, repository: ChatRepository? = nil) {
    self.chatID = chatID
    self.repository = repository
  }
  func request(_ request: PageRequest) async throws -> HistoryPage {
    guard !closed, request.chatID == chatID, let repository else { throw RepoError.cancelled }
    generation += 1
    let ticket = generation
    let page = try await repository.history(request)
    guard !closed, ticket == generation, !Task.isCancelled else { throw RepoError.cancelled }
    apply(page, chatID: request.chatID, generation: ticket)
    return page
  }
  func apply(_ page: HistoryPage, chatID: ChatID, generation: Int) {
    guard !closed, self.chatID == chatID, self.generation == generation, page.rows.count <= 128,
      page.rows.allSatisfy({ $0.chatID == chatID })
    else { return }
    pages.append(page.rows)
    if pages.count > 3 { pages.removeFirst(pages.count - 3) }
  }
  func refreshKnownRow(_ message: Message) {
    for page in pages.indices {
      if let i = pages[page].firstIndex(where: {
        $0.id == message.id && $0.revision < message.revision
      }) {
        pages[page][i] = message
      }
    }
  }
  func seedKnownRows(_ rows: [Message]) {
    guard !closed, rows.count <= 384, rows.allSatisfy({ $0.chatID == chatID }),
      Set(rows.map(\.id)).count == rows.count
    else { return }
    let ordered = rows.sorted { $0.order < $1.order }
    pages = stride(from: 0, to: ordered.count, by: 128).map {
      Array(ordered[$0..<min($0 + 128, ordered.count)])
    }
  }
  func close() {
    closed = true
    generation += 1
    pages.removeAll()
  }
}
