// Поддерживает местный перечень чатов, загружает поиск и передаёт изменения открытому экрану.
// Учитывает номер соединения и отсечку событий, чтобы опоздавший снимок не затёр более свежие
// данные.

import Foundation

extension NetworkSync {
  // Читает известные номера и границу событий, затем загружает недавние чаты и состояние
  // известных порциями. Сверяет соединение перед записью и показом. Архивные и более старые чаты
  // не считаются удалёнными только из-за отсутствия в недавних.
  func refreshStudioDirectory() async throws {
    let connection = connectionEpoch
    let (known, startedAtCursor) = try await store.perform { [cache] in
      (try cache.studioChatIDs($0), try cache.cursor($0))
    }
    let data = try await api.json("/v1/chats")
    var states: [Data] = []
    // Архивированный чат исчезает из недавних. Его сохранённые флаги сверяем отдельно,
    // не считая отсутствующие на первой странице чаты удалёнными или архивными.
    for offset in stride(from: 0, to: known.count, by: 128) {
      guard !closed, active, connection == connectionEpoch else { return }
      let ids = Array(known[offset..<min(offset + 128, known.count)])
      let body = try JSONEncoder().encode(["ids": ids])
      states.append(try await api.json("/v1/chats/states", body: body))
    }
    guard !closed, active, connection == connectionEpoch else { return }
    let snapshots = states
    let changes = try await store.perform { [cache] database in
      try cache.mergeStudioDirectorySnapshot(
        database, recent: data, states: snapshots, startedAtCursor: startedAtCursor)
    }
    guard !closed, active, connection == connectionEpoch else { return }
    ui.offer(changes)
    onStudioRecentChanged?()
  }

  // Отправляет сохранённый номер черновика, проверяет форму ответа и записывает карточку местно.
  // Экран получает изменения после записи, поэтому созданный чат можно открыть сразу.
  func createStudioThread(id threadID: UUID) async throws -> ChatID {
    guard !closed else { throw CancellationError() }
    let body = try JSONEncoder().encode(["id": threadID.uuidString.lowercased()])
    let response = try await submitStudioThread(body)
    guard let chat = try WireObject(data: response).value["chat"] as? [String: Any] else {
      throw RepoError.corrupt
    }
    let id = try WireObject(chat).int("id")
    let data = try JSONSerialization.data(withJSONObject: ["chats": [chat]])
    let deltas = try await store.perform { [cache] in try cache.mergeChats($0, data: data) }
    guard !closed else { throw CancellationError() }
    ui.offer(deltas)
    return id
  }

  // При временной ошибке ждёт и повторяет запрос с тем же номером черновика. Это позволяет
  // получить уже созданный чат при потере ответа. После закрытия сеанса и при остальных ошибках
  // повтор прекращается.
  private func submitStudioThread(_ body: Data) async throws -> Data {
    let delays: [UInt64] = [300_000_000, 800_000_000]
    for delay in delays {
      do { return try await api.json("/v1/demo/chats", body: body) } catch {
        let recoverable: Bool
        switch error {
        case let error as URLError:
          recoverable = [
            .networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet,
          ].contains(error.code)
        case let error as NetworkFailure:
          recoverable = [500, 502, 503, 504].contains(error.status)
        default:
          recoverable = false
        }
        guard recoverable, !closed else { throw error }
        try await Task.sleep(nanoseconds: delay)
      }
    }
    guard !closed else { throw CancellationError() }
    return try await api.json("/v1/demo/chats", body: body)
  }

  // Читает сохранённую страницу недавних из местной базы. Список можно показать до обновления по
  // сети.
  func cachedStudioRecent() async throws -> StudioRecentPage {
    try await store.perform { [cache] in try cache.studioRecent($0) }
  }
  // Передаёт раздел, поисковую строку и границы страницы на сервер. Кодирует знак плюса отдельно,
  // чтобы при поиске он сохранился и не превратился в пробел.
  func studioThreads(view: String, query: String, offset: Int, limit: Int) async throws
    -> [StudioThread]
  {
    struct Page: Decodable { let threads: [StudioThread] }
    var path = URLComponents()
    path.path = "/v1/kandinsky/threads"
    path.queryItems = [
      .init(name: "view", value: view), .init(name: "q", value: query),
      .init(name: "offset", value: String(offset)), .init(name: "limit", value: String(limit)),
    ]
    // Сервер читает обычный плюс в строке поиска как пробел. Кодируем плюс отдельно.
    path.percentEncodedQuery = path.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let relative = path.string else { throw RepoError.invalidInput }
    return try JSONDecoder().decode(Page.self, from: await api.json(relative)).threads
  }
  // Записывает полученную карточку и сохраняет служебные отметки списка. Экран может открыть
  // выбранный чат, не сбрасывая результаты последней сверки.
  func admitStudioThread(_ thread: StudioThread) async throws {
    let data = try JSONEncoder().encode(["chats": [thread]])
    let deltas = try await store.perform { [cache] in
      try cache.mergeChats($0, data: data, preserveDirectoryMetadata: true)
    }
    guard !closed else { throw CancellationError() }
    ui.offer(deltas)
  }
  // Отправляет изменение на сервер и сохраняет карточку из его ответа. Так экран использует
  // подтверждённые название, архив или закрепление.
  func changeStudioThread(_ id: ChatID, change: StudioThreadChange) async throws {
    let data = try await api.json(
      "/v1/kandinsky/threads/\(id)", body: JSONEncoder().encode(change), method: "PATCH")
    try await admitStudioThread(JSONDecoder().decode(StudioThread.self, from: data))
  }
  // После подтверждения сервером убирает чат из местной базы и собирает сведения об удалённых
  // сообщениях в одной записи. Экран получает событие только после этого, иначе при повторном
  // открытии мог бы прочитать старые строки.
  func deleteStudioThread(_ id: ChatID) async throws {
    _ = try await api.json("/v1/kandinsky/threads/\(id)", method: "DELETE")
    let deltas = try await store.perform { [cache] db in
      try db.transaction {
        guard let removed = try cache.retireStudioThread(db, chat: id) else {
          return [MessageDelta]()
        }
        return try cache.deltas(db, touched: [id: []], removed: [id: removed], reason: .sync)
      }
    }
    ui.offer(deltas)
  }
}
