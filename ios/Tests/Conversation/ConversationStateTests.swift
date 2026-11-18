import UIKit
import XCTest

@testable import Kandinsky

@MainActor final class ConversationStateTests: XCTestCase {
  func testIdleDraftSavesLatestInputWithoutSendingOrClosing() async throws {
    let h = try await RepositoryHarness.open()
    let state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    let persisted = expectation(description: "Черновик записан после паузы в печати")
    state.persistStudioDraft = { _, _ in
      XCTAssertFalse(Task.isCancelled)
      persisted.fulfill()
    }
    state.editDraft(Draft(text: "Первый текст"))
    state.editDraft(Draft(text: "Последний текст"))
    await fulfillment(of: [persisted], timeout: 2)
    let saved = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(saved.text, "Последний текст")
    XCTAssertNil(state.lastError)
    state.persistStudioDraft = nil
    await state.close()
    try await h.close()
  }

  func testIdleNewDraftSavesTextAndPhotoBeforeAnyServerChatExists() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { try NetworkSchema.install($0) }
    let sync = NetworkSync(
      profile: NetworkProfile(
        userId: 1, deviceId: UUID().uuidString, name: "Idle draft test",
        token: String(repeating: "a", count: 64), expiresAtMs: Int64.max),
      store: h.store, local: h.repo)
    let media = MediaStore(store: h.store)
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let photo = try await media.stageSelection(sourceURL: fixture, mime: "image/jpeg")
    let record = StudioDraftRecord(identity: UUID(), draft: Draft())
    _ = try await sync.beginStudioDraft(record)
    let state = ConversationState(repository: h.repo)
    let persisted = expectation(description: "Новый черновик с фото записан после паузы")
    state.persistStudioDraft = { chat, draft in
      XCTAssertNil(chat)
      try await sync.saveStudioDraft(draft, identity: record.identity)
      persisted.fulfill()
    }
    state.openStudioDraft()
    var draft = Draft(text: "Оживить это фото")
    draft.attachmentDrafts = [photo]
    state.editDraft(draft)
    await fulfillment(of: [persisted], timeout: 2)
    let saved = try await sync.savedStudioDraft()
    XCTAssertEqual(saved?.identity, record.identity)
    XCTAssertEqual(saved?.draft.text, draft.text)
    XCTAssertEqual(saved?.draft.attachmentDrafts.map(\.id), [photo.id])
    XCTAssertNil(state.lastError)
    state.persistStudioDraft = nil
    await state.close()
    media.close()
    sync.close()
    try await h.close()
  }

  func testScrollingSavesLatestPositionWithoutEditingOrClosing() async throws {
    let h = try await RepositoryHarness.open()
    let state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    for message in 1...100 {
      state.anchor = ReadingAnchor(messageID: Int64(message), fraction: 0.4, followsBottom: false)
    }
    try await Task.sleep(nanoseconds: 400_000_000)
    let stored = try await h.repo.position(chatID: 2)
    XCTAssertEqual(stored, state.anchor, "Прокрутка должна сохранять место без изменения черновика")
    let draft = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(draft.text, "")
    await state.close()
    try await h.close()
  }

  func testDraftWriteCannotOverwriteNewerReadingPosition() async throws {
    let h = try await RepositoryHarness.open()
    let state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    state.anchor = ReadingAnchor(messageID: 1, followsBottom: false)
    let newer = ReadingAnchor(messageID: 2, fraction: 0.5, followsBottom: false)
    state.persistStudioDraft = { _, _ in
      state.anchor = newer
      try await Task.sleep(nanoseconds: 400_000_000)
    }
    try await state.flush()
    state.persistStudioDraft = nil
    let stored = try await h.repo.position(chatID: 2)
    XCTAssertEqual(stored, newer, "Запись черновика не должна возвращать прежнее место чтения")
    await state.close()
    try await h.close()
  }

  func testUnboundDraftFlushPersistsBeforeChatAndOldBindingKeepsANewerDraft() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { try NetworkSchema.install($0) }
    let sync = NetworkSync(
      profile: NetworkProfile(
        userId: 1, deviceId: UUID().uuidString, name: "Draft test",
        token: String(repeating: "a", count: 64), expiresAtMs: Int64.max),
      store: h.store, local: h.repo)
    let first = StudioDraftRecord(identity: UUID(), draft: Draft())
    _ = try await sync.beginStudioDraft(first)
    let state = ConversationState(repository: h.repo)
    state.persistStudioDraft = { chat, draft in
      if chat == nil {
        try await sync.saveStudioDraft(draft, identity: first.identity)
      } else {
        try await sync.finishStudioDraft(identity: first.identity)
      }
    }
    state.openStudioDraft()
    state.editDraft(Draft(text: "До первого запроса"))
    try await state.flush()
    let saved = try await sync.savedStudioDraft()
    XCTAssertEqual(saved?.identity, first.identity)
    XCTAssertEqual(saved?.draft.text, "До первого запроса")
    let newer = StudioDraftRecord(identity: UUID(), draft: Draft(text: "Новый черновик"))
    _ = try await sync.beginStudioDraft(newer)
    try await state.flush()
    state.bindStudioDraft(chatID: 2)
    try await state.flush()
    let retained = try await sync.savedStudioDraft()
    XCTAssertEqual(retained?.identity, newer.identity)
    XCTAssertEqual(retained?.draft.text, "Новый черновик")
    let boundDraft = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(boundDraft.text, "До первого запроса")
    await state.close()
    sync.close()
    try await h.close()
  }

  func testUnboundSourceIsProtectedFromMediaRecovery() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    media.pendingReferences = NetworkMedia.pendingReferences
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let source = try await media.stageSelection(sourceURL: fixture, mime: "image/jpeg")
    var draft = Draft()
    draft.attachmentDrafts = [source]
    let body = try JSONSerialization.data(withJSONObject: [
      "identity": UUID().uuidString,
      "draft": JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)),
    ])
    let protected = try await h.store.perform { db in
      try NetworkSchema.install(db)
      try db.execute(
        "INSERT OR REPLACE INTO net_state(key,value) VALUES(?,?)",
        [.text("studio.newDraft"), .text(String(decoding: body, as: UTF8.self))])
      return try NetworkMedia.pendingReferences(db)
    }
    XCTAssertTrue(
      protected.contains(source.relativePath),
      "Новый черновик должен защищать своё фото до создания чата")
    try await media.recover()
    let file = try MediaStore.fileURL(root: h.root, relative: source.relativePath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    media.close()
    try await h.close()
  }

  func testSharedUploadSnapshotRejectsInvalidBoundsAndReplacesCompletedTransfers() async throws {
    let h = try await RepositoryHarness.open()
    let sync = NetworkSync(
      profile: NetworkProfile(
        userId: 1, deviceId: UUID().uuidString, name: "Upload test",
        token: String(repeating: "a", count: 64), expiresAtMs: Int64.max),
      store: h.store, local: h.repo)
    defer { sync.close() }
    let row: [String: Any] = [
      "id": UUID().uuidString, "deviceId": UUID().uuidString,
      "received": 250, "total": 1000, "mime": "image/jpeg",
    ]
    func packet(_ rows: [[String: Any]]) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["type": "kandinsky.uploads", "uploads": rows])
    }
    try sync.acceptStudioTransfers(packet([row]))
    XCTAssertEqual(sync.studioTransfers.first?.progress, 0.25)
    for (key, value) in [
      ("received", -1), ("received", 1001), ("total", 0), ("total", 20 * 1024 * 1024 + 1),
    ] {
      var invalid = row
      invalid[key] = value
      XCTAssertThrowsError(try sync.acceptStudioTransfers(packet([invalid])))
      XCTAssertEqual(sync.studioTransfers.first?.progress, 0.25)
    }
    XCTAssertThrowsError(try sync.acceptStudioTransfers(packet([row, row])))
    XCTAssertThrowsError(try sync.acceptStudioTransfers(packet(Array(repeating: row, count: 9))))
    try sync.acceptStudioTransfers(packet([]))
    XCTAssertTrue(sync.studioTransfers.isEmpty)
    try await h.close()
  }

  func testRetrySurvivesLostReplyAndReopening() async throws {
    let harness = try await RepositoryHarness.open()
    let id = "11111111-2222-3333-4444-555555555555"
    let state = ConversationState(repository: harness.repo)
    var slot = StudioGeneration.Slot(id: id, status: .failed, blobId: nil, progress: nil)
    var blocked = slot
    blocked.moderated = true
    XCTAssertNil(state.beginSlotRetry(blocked))
    let key = try XCTUnwrap(state.beginSlotRetry(slot))
    XCTAssertEqual(key.uuidString.lowercased(), "9c86e889-f9b0-862a-b44c-e97dd01a8b40")
    XCTAssertNil(state.beginSlotRetry(slot))
    let reopened = ConversationState(repository: harness.repo)
    XCTAssertEqual(reopened.beginSlotRetry(slot), key)
    reopened.finishSlotRetry(id)
    slot.runId = key.uuidString
    XCTAssertNotEqual(reopened.beginSlotRetry(slot), key)
    try await harness.close()
  }

  /// Отдельный обработчик применения параметров в этой проверке срабатывать не должен.
  func testChoosingFourResultsAppliesBeforeClosingSettings() throws {
    var options = KandinskyOptions()
    let sheet = StudioGenerationSheet(options: options)
    let capabilities = StudioCapabilities(
      quality: [StudioChoice(id: "standard", name: "Стандарт", sizes: nil)],
      resolutions: [StudioChoice(id: "standard", name: "1024 × 1024", sizes: nil)],
      aspects: ["1:1"], duration_seconds: [], max_count: 4, negative_prompt: false, guidance: nil
    )
    sheet.showSettings(capabilities, onCountChange: { options.count = $0 }) { _ in
      XCTFail("The count must reach the composer before tapping Done")
    }
    func findCountControl(in view: UIView) -> UIControl? {
      if view.accessibilityIdentifier == "studio.option.Количество.4" { return view as? UIControl }
      return view.subviews.lazy.compactMap { findCountControl(in: $0) }.first
    }
    let count = try XCTUnwrap(findCountControl(in: sheet.view))
    count.sendActions(for: .touchUpInside)
    XCTAssertEqual(options.wire["count"] as? Int, 4)
  }
  func testSelectionSurvivesLegacyDraftRewriteAndLegacyRecovery() async throws {
    var h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let source = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let original = try Data(contentsOf: source)
    var commands: [SendCommand] = []
    for index in 0..<3 {
      let asset = try await media.stageSelection(sourceURL: source, mime: "image/jpeg")
      commands.append(
        SendCommand(
          operationID: UUID().uuidString, chatID: 2, kind: .photo,
          caption: index == 0 ? "Одна подпись" : "", attachments: [asset]))
    }
    var state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    state.editDraft(Draft(text: "До отката"))
    h.faults.arm(.afterCommitBeforeReply)
    await state.sendMediaBatch(commands)
    XCTAssertNotNil(state.lastError)
    await state.close()
    media.close()
    let root = h.root
    try await h.store.perform { db in
      let row = try XCTUnwrap(
        db.rows("SELECT attachmentDraft,revision FROM drafts WHERE chatId=2").first)
      let value = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(row["attachmentDraft"]!.string.utf8))
          as? [String: Any])
      let known: Set<String> = [
        "text", "attachmentDrafts", "replyToID", "revision", "operationID", "pendingSend",
        "pendingRevision",
      ]
      var legacy = value.filter { known.contains($0.key) }
      legacy["text"] = "Черновик старого клиента"
      legacy["revision"] = row["revision"]!.int + 1
      let json = String(decoding: try JSONSerialization.data(withJSONObject: legacy), as: UTF8.self)
      try db.execute(
        "UPDATE drafts SET text=?,attachmentDraft=?,revision=revision+1 WHERE chatId=2",
        [.text("Черновик старого клиента"), .text(json)])
      var references = Set(
        try db.rows("SELECT relativePath FROM attachments").map { $0["relativePath"]!.string })
      for record in try db.rows("SELECT attachmentDraft FROM drafts") {
        let saved = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(record["attachmentDraft"]!.string.utf8))
            as? [String: Any])
        let pending = saved["pendingSend"] as? [String: Any]
        for attachment in (saved["attachmentDrafts"] as? [[String: Any]] ?? [])
          + (pending?["attachments"] as? [[String: Any]] ?? [])
        {
          if let path = attachment["relativePath"] as? String { references.insert(path) }
        }
      }
      for name in ["staging", "objects"] {
        let dir = root.appendingPathComponent("media/" + name)
        for file
          in (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        {
          if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
            name == "staging" || !references.contains("objects/" + file.lastPathComponent)
          {
            try FileManager.default.removeItem(at: file)
          }
        }
      }
    }
    h = try await h.reopen()
    let restoredMedia = MediaStore(store: h.store)
    defer { restoredMedia.close() }
    try await restoredMedia.recover()
    for command in commands {
      let file = try restoredMedia.fileURL(command.attachments[0].relativePath)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: file.path),
        "Old cleanup cannot delete a pending selection original")
      if let bytes = try? Data(contentsOf: file) { XCTAssertEqual(bytes, original) }
    }
    state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    XCTAssertEqual(
      state.draft.pendingMediaBatch?.map(\.operationID), commands.map(\.operationID),
      "Intent must survive a legacy rewrite of draft JSON")
    await state.send()
    XCTAssertNil(state.lastError)
    XCTAssertEqual(state.draft.text, "Черновик старого клиента")
    let rows = try await h.store.perform { db in
      try db.rows(
        """
        SELECT m.kind,m.caption,o.token \
        FROM messages m \
        JOIN operations o ON o.messageId=m.id \
        WHERE m.chatId=2 \
        ORDER BY m.id
        """
      )
    }
    XCTAssertEqual(rows.map { $0["kind"]!.string }, ["photo", "photo", "photo"])
    XCTAssertEqual(rows.map { $0["caption"]!.string }, ["Одна подпись", "", ""])
    XCTAssertEqual(rows.map { $0["token"]!.string }, commands.map(\.operationID))
    await state.close()
    restoredMedia.close()
    try await h.close()
  }
  func testMediaBatchSurvivesLostReplyAndRestartWithoutConsumingComposerDraft() async throws {
    var h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let source = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    var commands: [SendCommand] = []
    for index in 0..<3 {
      let asset = try await media.stage(sourceURL: source, mime: "image/jpeg")
      commands.append(
        SendCommand(
          operationID: UUID().uuidString, chatID: 2, kind: .photo,
          caption: index == 0 ? "Подпись альбома" : "", attachments: [asset]))
    }
    try await h.repo.saveDraft(chatID: 2, draft: Draft(text: "Мой отдельный черновик"))
    try await h.store.perform { db in
      let row = try XCTUnwrap(db.rows("SELECT attachmentDraft FROM drafts WHERE chatId=2").first)
      var value = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(row["attachmentDraft"]!.string.utf8))
          as? [String: Any])
      value["pendingMediaBatch"] = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(commands))
      try db.execute(
        "UPDATE drafts SET attachmentDraft=? WHERE chatId=2",
        [.text(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))])
    }
    var state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    h.faults.arm(.afterCommitBeforeReply)
    await state.send()
    XCTAssertNotNil(state.lastError)
    XCTAssertEqual(state.draft.text, "Мой отдельный черновик")
    media.close()
    await state.close()
    h = try await h.reopen()
    let resumedMedia = MediaStore(store: h.store)
    try await resumedMedia.recover()
    for command in commands {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: try resumedMedia.fileURL(command.attachments[0].relativePath).path),
        "Pending batch owns every unsent source across recovery")
    }
    state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    await state.send()
    XCTAssertNil(state.lastError)
    XCTAssertEqual(state.draft.text, "Мой отдельный черновик")
    let count = try await h.messageCount(chatID: 2)
    XCTAssertEqual(count, 3)
    let rows = try await h.store.perform { db in
      try db.rows(
        """
        SELECT m.caption,o.token \
        FROM messages m \
        JOIN operations o ON o.messageId=m.id \
        WHERE m.chatId=2 \
        ORDER BY m.id
        """
      )
    }
    XCTAssertEqual(rows.map { $0["caption"]!.string }, ["Подпись альбома", "", ""])
    XCTAssertEqual(rows.map { $0["token"]!.string }, commands.map(\.operationID))
    resumedMedia.close()
    await state.close()
    try await h.close()
  }
  func testCommittedSendClearsDraftAndRestartPreservesIt() async throws {
    var h = try await RepositoryHarness.open()
    var state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    state.editDraft(Draft(text: "Привет 👋"))
    h.faults.arm(.beforeCommit)
    await state.send()
    XCTAssertEqual(state.draft.text, "Привет 👋")
    XCTAssertNotNil(state.lastError)
    let token = try XCTUnwrap(state.draft.operationID)
    h.faults.arm(.afterCommitBeforeReply)
    await state.send()
    XCTAssertEqual(state.draft.text, "Привет 👋")
    try await state.flush()
    await state.close()
    h = try await h.reopen()
    state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    XCTAssertEqual(state.draft.operationID, token)
    await state.send()
    XCTAssertEqual(state.draft.text, "")
    XCTAssertNil(state.draft.operationID)
    let count = try await h.messageCount(chatID: 2)
    XCTAssertEqual(count, 1)
    let chats = try await h.repo.chats(matching: "")
    XCTAssertEqual(chats.first?.lastPreview, "Привет 👋")
    state.editDraft(Draft(text: "Новый черновик"))
    state.anchor = ReadingAnchor(messageID: 1, fraction: 0.4, followsBottom: false)
    try await state.flush()
    await state.close()
    h = try await h.reopen()
    state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    XCTAssertEqual(state.draft.text, "Новый черновик")
    XCTAssertEqual(state.anchor?.messageID, 1)
    XCTAssertFalse(state.anchor?.followsBottom ?? true)
    await state.close()
    try await h.close()
  }
  func testNewestInputIsNotClearedByEarlierCommit() async throws {
    let h = try await RepositoryHarness.open()
    let state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    state.editDraft(Draft(text: "Первое"))
    let task = Task { await state.send() }
    while !state.isSending { await Task.yield() }
    state.editDraft(Draft(text: "Второе"))
    await task.value
    XCTAssertEqual(state.draft.text, "Второе")
    try await state.flush()
    let saved = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(saved.text, "Второе")
    await state.close()
    try await h.close()
  }
  func testLegacyDraftSurvivesCloseWhileOpenIsWaitingForSQLite() async throws {
    let h = try await RepositoryHarness.open()
    try await h.repo.saveDraft(chatID: 2, draft: Draft(text: "legacy draft", revision: 0))
    let gate = DispatchSemaphore(value: 0)
    let entered = expectation(description: "SQLite held")
    let blocker = Task.detached {
      try await h.store.perform { _ in
        entered.fulfill()
        _ = gate.wait(timeout: .now() + 3)
      }
    }
    await fulfillment(of: [entered], timeout: 2)
    let state = ConversationState(repository: h.repo)
    let opening = Task { try? await state.open(chatID: 2) }
    while state.chatID == nil { await Task.yield() }
    let closing = Task { await state.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gate.signal() }
    _ = try await blocker.value
    await opening.value
    await closing.value
    let saved = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(saved.text, "legacy draft")
    try await h.close()
  }

}
