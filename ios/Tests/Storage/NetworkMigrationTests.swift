import XCTest
import SQLite3
@testable import Kandinsky

final class NetworkMigrationTests: XCTestCase {
  func testRetryNumberSurvivesReopenUntilItsOwnReplyIsSaved() async throws {
    let harness = try await RepositoryHarness.open()
    let key = "generationRetry:2:9"
    let cache = NetworkStore(userID: 1)
    let first = try await harness.store.perform { db in
      try NetworkSchema.install(db)
      return try cache.pendingRetry(db, key: key, proposed: nil)
    }
    let reopened = try await harness.reopen()
    let response = Data(#"{"messages":[]}"#.utf8)
    let values = try await reopened.store.perform { db in
      let recovered = try cache.pendingRetry(db, key: key, proposed: UUID())
      _ = try cache.generationRows(
        db, chat: 2, data: response, retryKey: key, operation: UUID().uuidString)
      let afterLateReply = try cache.pendingRetry(db, key: key, proposed: nil)
      _ = try cache.generationRows(db, chat: 2, data: response, retryKey: key, operation: recovered)
      return [recovered, afterLateReply, try cache.pendingRetry(db, key: key, proposed: nil)]
    }
    XCTAssertEqual(Array(values.prefix(2)), [first, first])
    XCTAssertNotEqual(values.last, first)
    try await reopened.close()
  }

  /// Старые записи остаются в базе, поэтому обновление не стирает сохранённые данные.
  func testRetiredOperationsDoNotConsumePromptCapacity() async throws {
    let harness = try await RepositoryHarness.open()
    try await harness.store.perform { db in
      try NetworkSchema.install(db)
      for number in 0..<256 {
        try db.execute(
          "INSERT INTO net_outbox(id,action,payload,payloadBytes) VALUES(?,'command','{}',2)",
          [.text("old-\(number)")])
      }
    }
    let local = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: 1))
    let command = SendCommand(
      operationID: UUID().uuidString, chatID: 2, text: "Новый запрос генерации")
    let delta = try await local.send(command)
    XCTAssertEqual(delta.inserted.first?.text, command.text)
    XCTAssertEqual(
      try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE action='command'"), 256)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE action='send'"), 1)
    let ready = try await harness.store.perform { db in
      try NetworkJournal.readyOperations(db).map { $0["id"]!.string }
    }
    XCTAssertEqual(ready, [command.operationID.lowercased()])
    try await harness.close()
  }

  func testUnconfirmedPromptsStayAtTailThroughReplayAndLegacyUpgrade() async throws {
    let harness = try await RepositoryHarness.open()
    let local = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: 1))
    let cache = NetworkStore(userID: 1)
    let serverBase: Int64 = 1_837_550_888_340_132_174
    let first = SendCommand(operationID: UUID().uuidString, chatID: 2, text: "First queued prompt")
    let second = SendCommand(
      operationID: UUID().uuidString, chatID: 2, text: "Second queued prompt")
    /// Все такие сообщения принадлежат одному проверочному чату, чтобы сравнить местную отправку с
    /// серверным подтверждением.
    func wire(id: Int64, seq: Int64, sender: Int64, operation: String, text: String) -> [String:
      Any]
    {
      [
        "id": id, "chatId": 2, "seq": seq, "senderId": sender, "clientId": operation.lowercased(),
        "kind": "text", "text": text, "caption": "", "savedAtMs": 1_794_483_289_395, "revision": 1,
        "attachments": [] as [Any]
      ]
    }
    let old = wire(
      id: 90, seq: serverBase, sender: 0, operation: UUID().uuidString, text: "Previous answer")
    let history = try JSONSerialization.data(withJSONObject: ["messages": [old], "hasOlder": false])
    try await harness.store.perform { db in
      try NetworkSchema.install(db)
      try db.execute("INSERT INTO net_chats(chatID,title) VALUES(2,'Studio')")
      _ = try cache.history(db, chat: 2, data: history)
    }
    let firstID = try await local.send(first).inserted[0].id
    let secondID = try await local.send(second).inserted[0].id
    let queued = try await local.history(PageRequest(chatID: 2)).rows
    XCTAssertEqual(queued.map(\.text), ["Previous answer", first.text, second.text])

    let accepted = wire(
      id: 91, seq: serverBase + 2_048, sender: 1, operation: first.operationID, text: first.text)
    let answer = wire(
      id: 92, seq: serverBase + 2_049, sender: 0, operation: UUID().uuidString, text: "New answer")
    let ack = try JSONSerialization.data(withJSONObject: ["messages": [accepted]])
    let pulled = try JSONSerialization.data(withJSONObject: [
      "messages": [answer, accepted], "hasOlder": false
    ])
    try await harness.store.perform { db in
      _ = try cache.accepted(db, data: ack)
      _ = try cache.history(db, chat: 2, data: pulled)
      _ = try cache.accepted(db, data: ack)
      try db.execute("UPDATE messages SET sortKey=savedAt WHERE id=?", [.integer(secondID)])
      try NetworkSchema.install(db)
    }
    let recovered = try await local.history(PageRequest(chatID: 2)).rows
    XCTAssertEqual(
      recovered.map(\.text), ["Previous answer", first.text, "New answer", second.text])
    XCTAssertEqual(recovered[1].id, firstID)
    XCTAssertEqual(recovered[1].order.sortKey, serverBase + 2_048)
    XCTAssertEqual(recovered.last?.id, secondID)
    XCTAssertEqual(recovered.last?.delivery, .pending)
    let outbox = try await harness.store.perform { db in
      try db.rows("SELECT localID FROM net_outbox WHERE action='send'").map { $0["localID"]!.int }
    }
    XCTAssertEqual(outbox, [secondID])
    try await harness.close()
  }

  func testHistoryAndDeltaCarryImmutablePreviewLocationSnapshots() async throws {
    let h = try await RepositoryHarness.open(), cache = NetworkStore(userID: 1)
    let blob = "824d66cce0d64409ad4888a13792c7d4", preview = "b2cf77e3cafb4ba5ad916d15533f3298",
      replacement = String(repeating: "c", count: 64), client = UUID().uuidString.lowercased()
    func page(_ preview: String, _ revision: Int) throws -> Data {
      let a: [String: Any] = [
        "id": "source-photo", "blobId": blob, "previewBlobId": preview, "mime": "image/jpeg",
        "byteSize": 1967774, "rawWidth": 3000, "rawHeight": 1732, "orientation": 1,
        "durationMs": NSNull(), "thumbnailKey": blob
      ]
      let m: [String: Any] = [
        "id": 901, "chatId": 2, "seq": 1, "senderId": 2, "clientId": client, "kind": "photo",
        "text": "", "caption": "Настоящее фото", "replyToId": NSNull(), "savedAtMs": 1000,
        "revision": revision, "attachments": [a]
      ]
      return try JSONSerialization.data(withJSONObject: ["messages": [m], "hasOlder": false])
    }
    let firstData = try page(preview, 1), secondData = try page(replacement, 2)
    let firstDelta = try await h.store.perform { db in
      try NetworkSchema.install(db)
      try db.execute("INSERT INTO net_chats(chatID,title) VALUES(2,'Peer')")
      return try cache.history(db, chat: 2, data: firstData)
    }
    let first = try XCTUnwrap(firstDelta.first?.updated.first?.attachments.first?.remoteLocation)
    let network = NetworkChatRepository(local: h.repo, wake: {})
    let initialPage = try await network.history(PageRequest(chatID: 2)),
      initial = try XCTUnwrap(initialPage.rows.first?.attachments.first?.remoteLocation)
    XCTAssertEqual(first, initial)
    XCTAssertEqual(first.previewBlobID, preview)
    XCTAssertEqual(first.blobID, blob)
    let secondDelta = try await h.store.perform { try cache.history($0, chat: 2, data: secondData) }
    let updated = try XCTUnwrap(secondDelta.first?.updated.first?.attachments.first?.remoteLocation)
    let newPage = try await network.history(PageRequest(chatID: 2)),
      current = try XCTUnwrap(newPage.rows.first?.attachments.first?.remoteLocation)
    XCTAssertEqual(updated, current)
    XCTAssertEqual(current.previewBlobID, replacement)
    XCTAssertEqual(first.previewBlobID, preview)
    XCTAssertEqual(
      initial.previewBlobID, preview, "Earlier page values remain bound to their own revision")
    XCTAssertEqual(try h.rawScalar("PRAGMA user_version"), 3)
    try await h.close()
  }

  @MainActor func testAccountListsBothOriginalHistoriesOnce() async throws {
    let profile = try StudioTestServer.profile()
    let api = NetworkAPI(profile: profile)
    defer { api.close() }
    let index = try WireObject(data: await api.json("/v1/chats")).array("chats")
    let chats = try index.map { try WireObject($0) }
    let ids = try chats.map { try $0.int("id") }
    XCTAssertEqual(Set(ids).count, ids.count)
    for title in ["Длинная история", "Плотная медиалента"] {
      XCTAssertEqual(try chats.filter { try $0.string("title") == title }.count, 1)
    }
  }

  @MainActor func testLongHistoryOpensInTwoBoundedNonoverlappingPages() async throws {
    let profile = try StudioTestServer.profile()
    let api = NetworkAPI(profile: profile)
    defer { api.close() }
    let chat = try await StudioTestServer.chat("Длинная история", api: api)
    let path = "/v1/chats/\(chat)/history?limit=128"
    func sequences(_ path: String) async throws -> [Int64] {
      let page = try WireObject(data: await api.json(path))
      XCTAssertEqual(page.value["hasOlder"] as? Bool, true)
      let rows = try page.array("messages")
      XCTAssertTrue((1...128).contains(rows.count))
      return try rows.map { try WireObject($0).int("seq") }
    }
    let newest = try await sequences(path)
    let boundary = try XCTUnwrap(newest.min())
    let older = try await sequences(path + "&before=\(boundary)")
    XCTAssertTrue(older.allSatisfy { $0 < boundary })
    XCTAssertEqual(Set(older + newest).count, older.count + newest.count)
  }

  func testSavedCursorWaitsForConfirmationAcrossReopen() async throws {
    let harness = try await RepositoryHarness.open()
    let cache = NetworkStore(userID: 1)
    try await harness.store.perform { db in
      try NetworkSchema.install(db)
      try cache.state(db, "cursor", "12")
      try cache.state(db, "ackedCursor", "10")
    }
    let reopened = try await harness.reopen()
    try await reopened.store.perform { db in
      XCTAssertEqual(try cache.cursorAwaitingConfirmation(db), 12)
      try cache.state(db, "ackedCursor", "12")
      XCTAssertNil(try cache.cursorAwaitingConfirmation(db))
      try cache.state(db, "cursor", "13")
      XCTAssertEqual(try cache.cursorAwaitingConfirmation(db), 13)
    }
    try await reopened.close()
  }

  func testChatMetadataRefreshPreservesPagingAndDoesNotCountReplayTwice() async throws {
    let h = try await RepositoryHarness.open(), cache = NetworkStore(userID: 1000)
    try await h.store.perform { try NetworkSchema.install($0) }
    let message: [String: Any] = [
      "id": 901, "chatId": 4000, "seq": 1, "senderId": 0,
      "clientId": UUID().uuidString.lowercased(), "kind": "text", "text": "Генерация завершена",
      "caption": "", "replyToId": NSNull(), "savedAtMs": 1000, "revision": 1, "attachments": []
    ]
    let chats = try JSONSerialization.data(withJSONObject: [
      "chats": [
        [
          "id": 4000, "title": "Результаты", "pinned": false, "unreadCount": 0, "lastSeq": 0
        ]
      ]
    ])
    let events = try JSONSerialization.data(withJSONObject: [
      "type": "events", "cursor": 1,
      "events": [["seq": 1, "chatId": 4000, "kind": "message", "message": message]]
    ])
    let missing = try await h.store.perform { try cache.hasUnknownChats($0, data: events) }
    XCTAssertTrue(missing)
    let values = try await h.store.perform { db -> (Int64, Int64, Int64, Bool) in
      _ = try cache.mergeChats(db, data: chats)
      try db.execute("UPDATE net_chats SET hasOlder=0 WHERE chatID=4000")
      _ = try cache.mergeChats(db, data: chats)
      _ = try cache.events(db, data: events)
      _ = try cache.events(db, data: events)
      _ = try cache.mergeChats(db, data: chats)
      return (
        try db.scalar("SELECT count(*) FROM messages WHERE chatId=4000"),
        try db.scalar("SELECT unreadCount FROM chats WHERE id=4000"),
        try db.scalar("SELECT hasOlder FROM net_chats WHERE chatID=4000"),
        try cache.hasUnknownChats(db, data: events)
      )
    }
    XCTAssertEqual(values.0, 1)
    XCTAssertEqual(values.1, 1)
    XCTAssertEqual(values.2, 0)
    XCTAssertFalse(values.3)
    try await h.close()
  }

  /// Поздняя страница прежней истории не должна вернуть скрытое сообщение.
  func testReplayRollsBackAsBatchAndLocalTombstoneWinsOverOldHistory() async throws {
    let harness = try await RepositoryHarness.open()
    defer { Task { try? await harness.store.close() } }
    let store = harness.store, cache = NetworkStore(userID: 1)
    try await store.perform { db in
      try NetworkSchema.install(db)
      try db.execute("INSERT OR IGNORE INTO chats(id,title) VALUES(2,'Peer')")
      try db.execute("INSERT OR IGNORE INTO net_chats(chatID,title) VALUES(2,'Peer')")
    }
    let message: [String: Any] = [
      "id": 101, "chatId": 2, "seq": 101, "senderId": 2, "clientId": UUID().uuidString.lowercased(),
      "kind": "text", "text": "Independent wire fixture", "caption": "", "replyToId": NSNull(),
      "savedAtMs": 1000, "revision": 1, "attachments": []
    ]
    let first: [String: Any] = ["seq": 1, "kind": "message", "chatId": 2, "message": message]
    let invalid = try JSONSerialization.data(withJSONObject: [
      "type": "events", "events": [first, ["seq": 2, "kind": "unknown", "chatId": 2]], "cursor": 2
    ])
    do {
      _ = try await store.perform { try cache.events($0, data: invalid) }
      XCTFail("Unknown persistent event must fail the complete transaction")
    } catch {}
    let rolledBack = try await store.perform { db in
      (try cache.cursor(db), try db.scalar("SELECT count(*) FROM messages"))
    }
    XCTAssertEqual(rolledBack.0, 0)
    XCTAssertEqual(rolledBack.1, 0)
    let good = try JSONSerialization.data(withJSONObject: [
      "type": "events", "events": [first], "cursor": 1
    ])
    let id = try await store.perform { db -> Int64 in
      _ = try cache.events(db, data: good)
      _ = try cache.events(db, data: good)
      return try db.scalar("SELECT localID FROM net_messages WHERE serverID=101")
    }
    let local = SQLiteChatRepository(store: store, journal: NetworkJournal(userID: 1))
    _ = try await local.delete(messageID: id)
    let history = try JSONSerialization.data(withJSONObject: [
      "messages": [message], "hasOlder": false
    ])
    let count = try await store.perform { db -> Int64 in
      _ = try cache.history(db, chat: 2, data: history)
      return try db.scalar("SELECT count(*) FROM messages")
    }
    XCTAssertEqual(count, 0, "Late history must not recreate a hidden message")
  }

  func testOutboxAndMessageCommitTogetherAcrossLostReply() async throws {
    let harness = try await RepositoryHarness.open()
    try await harness.store.perform { database in try NetworkSchema.install(database) }
    let repository = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: 1))
    let command = SendCommand(
      operationID: UUID().uuidString, chatID: 2, text: "Keep this across reconnect")
    harness.faults.arm(.beforeCommit)
    do {
      _ = try await repository.send(command)
      XCTFail("Commit fault expected")
    } catch {}
    let rolledBack = try await harness.store.perform { database in
      (
        try database.scalar("SELECT count(*) FROM messages"),
        try database.scalar("SELECT count(*) FROM net_outbox")
      )
    }
    XCTAssertEqual(rolledBack.0, 0)
    XCTAssertEqual(rolledBack.1, 0)
    harness.faults.arm(.afterCommitBeforeReply)
    do {
      _ = try await repository.send(command)
      XCTFail("Lost reply expected")
    } catch {}
    let committed = try await harness.store.perform { database in
      (
        try database.scalar("SELECT count(*) FROM messages"),
        try database.scalar("SELECT count(*) FROM net_outbox")
      )
    }
    XCTAssertEqual(committed.0, 1)
    XCTAssertEqual(committed.1, 1, "A visible message must have its durable outgoing command")
    let replay = try await repository.send(command)
    XCTAssertEqual(replay.inserted.first?.delivery, .pending)
    try await harness.close()
  }

  func testRemovingRejectedMessageDoesNotLeaveBlockingDelete() async throws {
    let harness = try await RepositoryHarness.open(), store = harness.store
    try await store.perform { try NetworkSchema.install($0) }
    let local = SQLiteChatRepository(store: store, journal: NetworkJournal(userID: 1))
    let command = SendCommand(operationID: UUID().uuidString, chatID: 2, text: "Rejected by server")
    let delta = try await local.send(command), id = delta.inserted[0].id
    try await store.perform { db in
      try db.execute("UPDATE net_outbox SET errorCode='invalid_text'")
      try db.execute("UPDATE messages SET deliveryState='failed' WHERE id=?", [.integer(id)])
    }
    _ = try await local.delete(messageID: id)
    let pending = try await store.perform { try $0.scalar("SELECT count(*) FROM net_outbox") }
    XCTAssertEqual(pending, 0, "A rejected send has no remote message to delete")
    try await harness.close()
  }

  func testVersionTwoHistorySurvivesAddingDeliveryState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "network-v2-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var raw: OpaquePointer?
    XCTAssertEqual(sqlite3_open(root.appendingPathComponent("chat.sqlite3").path, &raw), SQLITE_OK)
    let database = SQLiteConnection(try XCTUnwrap(raw))
    // Схема прежней второй версии задаётся независимо от проверяемого обновления
    let fixture = [
      "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
      """
      CREATE TABLE chats(id INTEGER PRIMARY KEY,title TEXT NOT NULL,\
      avatarKind TEXT NOT NULL DEFAULT 'initial',lastMessageId INTEGER,\
      updatedSortKey INTEGER NOT NULL DEFAULT 0,unreadCount INTEGER NOT NULL DEFAULT 0,\
      pinned INTEGER NOT NULL DEFAULT 0)
      """,
      """
      CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT,\
      chatId INTEGER NOT NULL REFERENCES chats(id),sortKey INTEGER NOT NULL,\
      kind TEXT NOT NULL,text TEXT NOT NULL DEFAULT '',caption TEXT NOT NULL DEFAULT '',\
      replyToId INTEGER,revision INTEGER NOT NULL DEFAULT 1,savedAt INTEGER NOT NULL,\
      direction TEXT NOT NULL DEFAULT 'incoming',searchText TEXT NOT NULL DEFAULT '')
      """,
      """
      CREATE TABLE attachments(id TEXT PRIMARY KEY,messageId INTEGER NOT NULL,\
      relativePath TEXT NOT NULL,mime TEXT NOT NULL,byteSize INTEGER NOT NULL,\
      width INTEGER NOT NULL DEFAULT 0,height INTEGER NOT NULL DEFAULT 0,durationMs INTEGER,\
      thumbnailKey TEXT NOT NULL DEFAULT '',orientation INTEGER NOT NULL DEFAULT 1)
      """,
      """
      CREATE TABLE drafts(chatId INTEGER PRIMARY KEY,text TEXT NOT NULL,\
      attachmentDraft TEXT,revision INTEGER NOT NULL DEFAULT 0)
      """,
      """
      CREATE TABLE reading_positions(chatId INTEGER PRIMARY KEY,messageId INTEGER,\
      offsetWithin TEXT NOT NULL,followsBottom INTEGER NOT NULL,\
      layoutVersion INTEGER NOT NULL)
      """,
      "CREATE TABLE operations(token TEXT PRIMARY KEY,payloadHash TEXT NOT NULL,messageId INTEGER NOT NULL)",
      "INSERT INTO chats(id,title) VALUES(2,'Existing chat')",
      "INSERT INTO messages(id,chatId,sortKey,kind,text,savedAt) VALUES(17,2,100,'text','preserve me',100)",
      "PRAGMA user_version=2"
    ]
    for statement in fixture { try database.execute(statement) }
    sqlite3_close_v2(raw)
    let store = try await SQLiteStore.open(root: root)
    let columns = try await store.perform { database in
      try database.rows("PRAGMA table_info(messages)").map { $0["name"]?.string ?? "" }
    }
    guard columns.contains("deliveryState") else {
      try await store.close()
      return XCTFail("Network migration must add a delivery state")
    }
    let values = try await store.perform { database in
      try database.rows("SELECT text,deliveryState FROM messages WHERE id=17").map {
        ($0["text"]?.string ?? "", $0["deliveryState"]?.string ?? "")
      }
    }
    XCTAssertEqual(values.count, 1)
    XCTAssertEqual(values.first?.0, "preserve me")
    XCTAssertEqual(values.first?.1, "local")
    try await store.close()
  }
  func testOwnMediaRevisionKeepsOnlyAMatchingCachedBlob() async throws {
    let h = try await RepositoryHarness.open(), cache = NetworkStore(userID: 1)
    let client = UUID().uuidString.lowercased(), oldBlob = String(repeating: "a", count: 64),
      newBlob = String(repeating: "b", count: 64)
    func page(_ blob: String, _ revision: Int) throws -> Data {
      let a: [String: Any] = [
        "id": "wire-image", "blobId": blob, "mime": "image/jpeg", "byteSize": 100, "rawWidth": 120,
        "rawHeight": 80, "orientation": 1, "durationMs": NSNull(), "previewBlobId": NSNull(),
        "thumbnailKey": blob
      ]
      let row: [String: Any] = [
        "id": 501, "chatId": 2, "seq": 1, "senderId": 1, "clientId": client, "kind": "photo",
        "text": "", "caption": "Real media revision", "replyToId": NSNull(), "savedAtMs": 1000,
        "revision": revision, "attachments": [a]
      ]
      return try JSONSerialization.data(withJSONObject: ["messages": [row], "hasOlder": false])
    }
    let first = try page(oldBlob, 1), same = try page(oldBlob, 2), changed = try page(newBlob, 3)
    let paths = try await h.store.perform { db -> (String, String) in
      try NetworkSchema.install(db)
      try db.execute("INSERT OR IGNORE INTO chats(id,title) VALUES(2,'Peer')")
      try db.execute("INSERT OR IGNORE INTO net_chats(chatID,title) VALUES(2,'Peer')")
      _ = try cache.history(db, chat: 2, data: first)
      try db.execute(
        "UPDATE attachments SET relativePath='objects/own-original.jpg' WHERE id='net-501-0'")
      _ = try cache.history(db, chat: 2, data: same)
      let kept = try db.rows("SELECT relativePath FROM attachments WHERE id='net-501-0'").first![
        "relativePath"]!.string
      _ = try cache.history(db, chat: 2, data: changed)
      let replaced = try db.rows("SELECT relativePath FROM attachments WHERE id='net-501-0'")
        .first!["relativePath"]!.string
      return (kept, replaced)
    }
    XCTAssertEqual(
      paths.0, "objects/own-original.jpg", "A matching uploaded file should not be downloaded again"
    )
    XCTAssertEqual(
      paths.1, "remote/" + newBlob + ".jpg", "A new server blob must not reuse the old local photo")
    try await h.close()
  }

}
