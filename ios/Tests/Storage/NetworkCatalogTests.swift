import XCTest

@testable import Kandinsky

final class NetworkCatalogTests: XCTestCase {
  func testRetiredChatRefreshesVisibleDirectoryWithoutCatalogRows() async throws {
    let harness = try await RepositoryHarness.open()
    defer { Task { try? await harness.close() } }
    let cache = NetworkStore(userID: 1)
    let initial = try catalog(count: 2, initial: true)
    let retired = Data(
      #"{"cursor":1,"events":[{"seq":1,"chatId":1,"kind":"kandinsky.retired"}]}"#.utf8)
    let (changed, replayChanged, remaining) = try await harness.store.perform { db in
      try NetworkSchema.install(db)
      _ = try cache.bootstrap(db, data: initial)
      let first = try cache.directoryEvents(db, data: retired)
      let replay = try cache.directoryEvents(db, data: retired)
      return (first.directoryChanged, replay.directoryChanged, try cache.studioRecent(db).threads)
    }
    XCTAssertTrue(changed, "Удалённый чат должен исчезнуть из уже открытой панели")
    XCTAssertFalse(replayChanged)
    XCTAssertEqual(remaining.map(\.id), [2])
  }

  func testLateDirectorySnapshotCannotRestartFinishedIndicator() async throws {
    let harness = try await RepositoryHarness.open()
    defer { Task { try? await harness.close() } }
    let cache = NetworkStore(userID: 1)
    let snapshot = Data(
      #"{"chats":[{"id":1,"title":"Название из каталога","lastSeq":0,"unreadCount":0,"pinned":false,"archived":false,"activityAtMs":1000,"generating":true}]}"#
        .utf8)
    let completed = Data(
      #"{"cursor":1,"chats":[{"id":1,"activityAtMs":1000,"generating":false}],"events":[{"seq":1,"chatId":1,"kind":"deleted","messageId":999}]}"#
        .utf8)
    let (row, fresh) = try await harness.store.perform { db in
      try NetworkSchema.install(db)
      _ = try cache.mergeChats(db, data: snapshot, studioRecent: true)
      let requestCursor = try cache.cursor(db)
      _ = try cache.events(db, data: completed)
      _ = try cache.mergeStudioDirectorySnapshot(
        db, recent: snapshot, startedAtCursor: requestCursor)
      _ = try cache.mergeChats(db, data: snapshot, preserveDirectoryMetadata: true)
      let preserved = try XCTUnwrap(cache.studioRecent(db).threads.first)
      _ = try cache.mergeStudioDirectorySnapshot(
        db, recent: snapshot, startedAtCursor: cache.cursor(db))
      return (preserved, try XCTUnwrap(cache.studioRecent(db).threads.first))
    }
    XCTAssertFalse(row.generating)
    XCTAssertEqual(row.title, "Название из каталога")
    XCTAssertTrue(fresh.generating)
  }

  func testProgressEventsDoNotReloadTheDirectory() async throws {
    let harness = try await RepositoryHarness.open()
    defer { Task { try? await harness.close() } }
    let cache = NetworkStore(userID: 1)
    func event(_ cursor: Int, generating: Bool) throws -> Data {
      try JSONSerialization.data(withJSONObject: [
        "cursor": cursor,
        "chats": [
          [
            "id": 1, "title": "Чат", "lastSeq": 0, "unreadCount": 0,
            "pinned": false, "archived": false, "activityAtMs": 1000, "generating": generating,
          ]
        ],
        "events": [["seq": cursor, "chatId": 1, "kind": "deleted", "messageId": 999]],
      ])
    }
    let first = try event(1, generating: true)
    let progress = try event(2, generating: true)
    let completed = try event(3, generating: false)
    let idle = Data(#"{"cursor":0,"events":[]}"#.utf8)
    let flags = try await harness.store.perform { db in
      try NetworkSchema.install(db)
      return try [idle, first, progress, completed].map {
        try cache.directoryEvents(db, data: $0).directoryChanged
      }
    }
    XCTAssertEqual(flags, [false, true, false, true])
  }

  func testDirectoryEventsPreserveActivityAndBusyStateAcrossReopen() async throws {
    let harness = try await RepositoryHarness.open()
    defer { Task { try? await harness.close() } }
    let cache = NetworkStore(userID: 1)
    func packet(_ rows: [[String: Any]]) throws -> Data {
      try JSONSerialization.data(withJSONObject: [
        "chats": rows.map {
          $0.merging(["lastSeq": 0, "unreadCount": 0, "pinned": false, "archived": false]) {
            current, _ in current
          }
        }
      ])
    }
    let initial = try packet([
      ["id": 2, "title": "Сегодня", "activityAtMs": 2000, "generating": false],
      ["id": 1, "title": "Вчера", "activityAtMs": 1000, "generating": false],
    ])
    let changedRows = try packet([
      ["id": 1, "title": "Вчера", "activityAtMs": 3000, "generating": true]
    ])
    var event = try XCTUnwrap(JSONSerialization.jsonObject(with: changedRows) as? [String: Any])
    event["cursor"] = 1
    event["events"] = [["seq": 1, "chatId": 1, "kind": "deleted", "messageId": 999]]
    let changed = try JSONSerialization.data(withJSONObject: event)
    let page = try await harness.store.perform { database in
      try NetworkSchema.install(database)
      _ = try cache.mergeChats(database, data: initial, studioRecent: true)
      _ = try cache.events(database, data: changed)
      return try NetworkStore(userID: 1).studioRecent(database)
    }
    XCTAssertEqual(page.threads.map(\.id), [1, 2])
    let raw = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(page.threads[0])) as? [String: Any])
    XCTAssertEqual(raw["activityAtMs"] as? Int, 3000)
    XCTAssertEqual(raw["generating"] as? Bool, true)
    event["cursor"] = 2
    event["events"] = [["seq": 2, "chatId": 1, "kind": "deleted", "messageId": 999]]
    event["chats"] = [["id": 1, "activityAtMs": 3000, "generating": false]]
    let completed = try JSONSerialization.data(withJSONObject: event)
    let afterReplay = try await harness.store.perform { database in
      _ = try cache.events(database, data: completed)
      _ = try cache.events(database, data: completed)
      do {
        _ = try cache.events(database, data: changed)
        XCTFail("Старый курсор должен быть отклонён")
      } catch RepoError.corrupt {
      }
      return try cache.studioRecent(database)
    }
    XCTAssertFalse(try XCTUnwrap(afterReplay.threads.first).generating)
  }

  func testOldDirectoryPayloadRemainsReadable() throws {
    let raw = Data(
      #"{"id":1,"title":"Старый чат","lastSeq":0,"unreadCount":0,"pinned":false,"archived":false}"#
        .utf8)
    let thread = try JSONDecoder().decode(StudioThread.self, from: raw)
    XCTAssertEqual(thread.title, "Старый чат")
    XCTAssertEqual(thread.activityAtMs, 0)
    XCTAssertFalse(thread.generating)
  }

  /// Начальные поля добавляет отдельно, чтобы одним набором проверять первую загрузку и последующую
  /// сверку.
  private func catalog(count: Int, initial: Bool) throws -> Data {
    let chats: [[String: Any]] = (1...count).map { index in
      ["id": index, "title": "Чат \(index)", "lastSeq": 0, "unreadCount": 0, "pinned": false]
    }
    var packet: [String: Any] = ["chats": chats]
    if initial {
      packet["version"] = 1
      packet["userId"] = 1
      packet["cursor"] = 0
      packet["messages"] = [Any]()
    }
    return try JSONSerialization.data(withJSONObject: packet)
  }

  func testBootstrapAcceptsCompleteServerCatalog() async throws {
    for count in [128, 129, 200] {
      let harness = try await RepositoryHarness.open()
      defer { Task { try? await harness.close() } }
      let cache = NetworkStore(userID: 1)
      let snapshot = try catalog(count: count, initial: true)
      let page = try await harness.store.perform { database in
        try NetworkSchema.install(database)
        _ = try cache.bootstrap(database, data: snapshot)
        return try cache.studioRecent(database)
      }
      XCTAssertEqual(page.threads.map(\.id), (1...count).map(Int64.init))
      XCTAssertEqual(page.nextOffset, count == 200 ? 200 : nil)
      XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_chats"), count)
    }
  }

  func testRecentRefreshAcceptsCompleteServerCatalog() async throws {
    let harness = try await RepositoryHarness.open()
    defer { Task { try? await harness.close() } }
    let cache = NetworkStore(userID: 1)
    let snapshot = try catalog(count: 200, initial: false)
    let page = try await harness.store.perform { database in
      try NetworkSchema.install(database)
      _ = try cache.mergeChats(database, data: snapshot, studioRecent: true)
      return try cache.studioRecent(database)
    }
    XCTAssertEqual(page.threads.count, 200)
    XCTAssertEqual(page.nextOffset, 200)
  }

  func testOversizedCatalogRollsBackAndDefaultArrayBoundRemains() async throws {
    let harness = try await RepositoryHarness.open()
    defer { Task { try? await harness.close() } }
    let cache = NetworkStore(userID: 1)
    let snapshot = try catalog(count: 201, initial: true)
    try await harness.store.perform { try NetworkSchema.install($0) }
    do {
      _ = try await harness.store.perform { try cache.bootstrap($0, data: snapshot) }
      XCTFail("Каталог за пределом должен быть отклонён")
    } catch RepoError.corrupt {
    }
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_chats"), 0)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_state WHERE key='cursor'"), 0)
    XCTAssertThrowsError(
      try WireObject(["messages": Array(repeating: 0, count: 129)]).array("messages"))
  }
}
