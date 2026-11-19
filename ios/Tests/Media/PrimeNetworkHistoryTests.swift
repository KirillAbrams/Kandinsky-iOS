// Проверка сохранения плотной медиаленты порциями. Она сверяет сообщения и вложения по всей
// истории, чтобы граница страницы не потеряла или не повторила готовый результат.

import XCTest
@testable import Kandinsky

@MainActor final class PrimeNetworkHistoryTests: XCTestCase {
  // Читаем медиаленту назад порциями не больше ста двадцати восьми записей. Проверяем строгие
  // границы и уникальность номеров, затем сравниваем местное число сообщений с ответами. В
  // исходной истории должно быть триста восемьдесят четыре сообщения и сто девяносто два фото и
  // видео.
  func testDenseHistoryStoresTwoMessagesPerResultAcrossPages() async throws {
    let profile = try StudioTestServer.profile()
    let api = NetworkAPI(profile: profile)
    defer { api.close() }
    let chat = try await StudioTestServer.chat("Плотная медиалента", api: api)
    let harness = try await RepositoryHarness.open()
    let cache = NetworkStore(userID: profile.userId)
    try await harness.store.perform { db in
      try NetworkSchema.install(db)
      try db.execute("INSERT OR IGNORE INTO chats(id,title) VALUES(?,'Медиа')", [.integer(chat)])
    }
    var sequences = Set<Int64>()
    var before: Int64?
    var photos = 0
    var videos = 0
    for _ in 0..<4 {
      let query = before.map { "&before=\($0)" } ?? ""
      let data = try await api.json("/v1/chats/\(chat)/history?limit=128" + query)
      let page = try WireObject(data: data)
      let messages = try page.array("messages").map { try WireObject($0) }
      XCTAssertTrue((1...128).contains(messages.count))
      let values = try messages.map { try $0.int("seq") }
      let first = try XCTUnwrap(values.min())
      if let before { XCTAssertTrue(values.allSatisfy { $0 < before }) }
      before = first
      for value in values { XCTAssertTrue(sequences.insert(value).inserted) }
      photos += try messages.filter { try $0.string("kind") == "photo" }.count
      videos += try messages.filter { try $0.string("kind") == "video" }.count
      _ = try await harness.store.perform { try cache.history($0, chat: chat, data: data) }
      if page.value["hasOlder"] as? Bool == false { break }
    }
    XCTAssertEqual(sequences.count, 384)
    XCTAssertEqual(photos + videos, 192)
    XCTAssertGreaterThan(photos, 0)
    XCTAssertGreaterThan(videos, 0)
    let stored = try await harness.messageCount(chatID: chat)
    XCTAssertEqual(stored, sequences.count)
    try await harness.close()
  }

  func testScrollingNearTheStartLoadsAnEarlierPageOnlyOnce() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1" else {
      throw XCTSkip("Нужен отдельный местный сервер с исходной медиалентой")
    }
    let profile = try StudioTestServer.profile()
    let api = NetworkAPI(profile: profile)
    let (chat, latest) = try await StudioTestServer.recentMedia(api)
    let bootstrap = try await api.json("/v1/bootstrap")
    let harness = try await RepositoryHarness.open()
    let sync = NetworkSync(profile: profile, store: harness.store, local: harness.repo, api: api)
    defer { sync.close() }
    try await harness.store.perform { [cache = sync.cache] db in
      try NetworkSchema.install(db)
      _ = try cache.bootstrap(db, data: bootstrap)
      _ = try cache.history(db, chat: chat, data: latest)
    }
    let initial = try await harness.repo.index(chatID: chat)
    XCTAssertEqual(initial.count, 128)
    let top = try XCTUnwrap(initial.first)
    let online = expectation(description: "Сервер подтвердил открытие соединения")
    sync.onStatus = { if $0 == "В сети" { online.fulfill() } }
    sync.foreground(true)
    await fulfillment(of: [online], timeout: 8)
    sync.onStatus = nil

    let earlier = expectation(description: "Предыдущая страница записана до обновления экрана")
    earlier.assertForOverFulfill = true
    let initialIDs = Set(initial.map(\.messageID))
    sync.onDeltas = { changes in
      let additions = changes.filter { $0.chat.id == chat }.flatMap(\.updated)
      if additions.contains(where: { !initialIDs.contains($0.id) }) { earlier.fulfill() }
    }
    sync.viewport(chat: chat, anchor: ReadingAnchor())
    let anchor = ReadingAnchor(messageID: top.messageID, followsBottom: false)
    sync.viewport(chat: chat, anchor: anchor)
    sync.viewport(chat: chat, anchor: anchor)
    await fulfillment(of: [earlier], timeout: 8)

    let loaded = try await harness.repo.index(chatID: chat)
    XCTAssertEqual(loaded.count, 256)
    XCTAssertEqual(Set(loaded.map(\.messageID)).count, 256)
    XCTAssertEqual(Array(loaded.suffix(128).map(\.messageID)), initial.map(\.messageID))
    XCTAssertTrue(loaded.prefix(128).allSatisfy { $0.order < top.order })
    XCTAssertTrue(sync.history.loadingHistory.isEmpty)
    sync.close()
    try await harness.close()
  }
}
