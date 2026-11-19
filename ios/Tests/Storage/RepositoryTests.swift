// Использует временную базу для проверки страниц, повтора отправки, обновления старой схемы и
// сохранения черновиков.

import XCTest
import SQLite3
@testable import Kandinsky

final class RepositoryTests: XCTestCase {
  // Даёт всем сообщениям одно время, затем проходит страницы фото, роликов и движущихся картинок
  // в обе стороны. Ловит пропуски на равном времени и перестановку вложений альбома.
  func testVisualKeysetPagesSkipNonVisualRowsAndKeepAlbumOrder() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      let kinds = [
        2: "photo", 4: "voice", 5: "video", 6: "round", 7: "gif", 8: "sticker", 10: "photo",
        12: "photo"
      ]
      for id in 1...13 {
        let kind = kinds[id] ?? "text"
        try db.execute(
          "INSERT INTO messages(id,chatId,sortKey,kind,text,caption,savedAt) VALUES(?,2,42,?,'','caption',42)",
          [.integer(Int64(id)), .text(kind)])
        if [2, 5, 7, 10, 12].contains(id) {
          for name in (id == 2 ? ["z-album", "a-album"] : ["item-\(id)"]) {
            try db.execute(
              """
              INSERT INTO attachments(id,messageId,relativePath,mime,byteSize,width,height) \
              VALUES(?,?,?,'image/jpeg',1,120,80)
              """,
              [.text(name), .integer(Int64(id)), .text("network/" + name + ".jpg")])
          }
        }
      }
    }
    let newest = try await h.repo.history(PageRequest(chatID: 2, limit: 2, visualOnly: true))
    XCTAssertEqual(newest.rows.map(\.id), [10, 12])
    XCTAssertNil(newest.after)
    let previous = try await h.repo.history(
      PageRequest(chatID: 2, anchor: try XCTUnwrap(newest.before), limit: 2, visualOnly: true))
    XCTAssertEqual(previous.rows.map(\.id), [5, 7])
    let oldest = try await h.repo.history(
      PageRequest(chatID: 2, anchor: try XCTUnwrap(previous.before), limit: 2, visualOnly: true))
    XCTAssertEqual(oldest.rows.map(\.id), [2])
    XCTAssertNil(oldest.before)
    XCTAssertEqual(oldest.rows.first?.attachments.map(\.id), ["z-album", "a-album"])
    let newer = try await h.repo.history(
      PageRequest(
        chatID: 2, anchor: OrderKey(sortKey: 42, messageID: 7), direction: .newer, limit: 2,
        visualOnly: true))
    XCTAssertEqual(newer.rows.map(\.id), [10, 12])
    XCTAssertNil(newer.after)
    let around = try await h.repo.history(
      PageRequest(
        chatID: 2, anchor: OrderKey(sortKey: 42, messageID: 7), direction: .around, limit: 4,
        visualOnly: true))
    XCTAssertEqual(around.rows.map(\.id), [5, 7, 10, 12])
    let all = try await h.repo.history(PageRequest(chatID: 2))
    XCTAssertEqual(all.rows.count, 13)
    XCTAssertEqual(try h.integrity(), "ok")
    try await h.close()
  }
  // Повторяет одну отправку до и после открытия файла, затем теряет ответ после сохранения
  // второй. Проверяет сохранённые номера и итоговое число строк, чтобы повтор не создавал дубли.
  func testCommitRetryAndLostReplySurviveReopen() async throws {
    var h = try await RepositoryHarness.open()
    let command = SendCommand(operationID: "send-one", chatID: 2, text: "Привет 👋 O'Brien")
    let first = try await h.repo.send(command)
    let id = try XCTUnwrap(first.inserted.first?.id)
    XCTAssertEqual(id, 1)
    let retry = try await h.repo.send(command)
    XCTAssertEqual(retry.inserted.first?.id, id)
    h = try await h.reopen()
    let again = try await h.repo.send(command)
    XCTAssertEqual(again.inserted.first?.id, id)
    let count = try await h.messageCount(chatID: 2)
    XCTAssertEqual(count, 1)
    let chats = try await h.repo.chats(matching: "Alica")
    XCTAssertEqual(chats.first?.lastPreview, "Привет 👋 O'Brien")
    h.faults.arm(.afterCommitBeforeReply)
    let next = SendCommand(operationID: "lost-reply", chatID: 2, text: "Уже сохранено")
    do {
      _ = try await h.repo.send(next)
      XCTFail("lost reply fault expected")
    } catch {}
    h = try await h.reopen()
    _ = try await h.repo.send(next)
    let finalCount = try await h.messageCount(chatID: 2)
    XCTAssertEqual(finalCount, 2)
    XCTAssertEqual(try h.integrity(), "ok")
    try await h.close()
  }
  // Подставляет сбой перед подтверждением, нехватку места и повтор того же номера с другим
  // текстом. Проверяет, что остались прежнее сообщение, черновик и подпись карточки.
  func testRollbackFullAndPayloadMismatchPreserveState() async throws {
    let h = try await RepositoryHarness.open()
    _ = try await h.repo.send(SendCommand(operationID: "one", chatID: 2, text: "Сохранено"))
    try await h.repo.saveDraft(chatID: 2, draft: Draft(text: "Черновик 👨‍👩‍👧"))
    for fault in [RepoFault.beforeCommit, .storageFull] {
      h.faults.arm(fault)
      do {
        _ = try await h.repo.send(
          SendCommand(operationID: "fail-\(fault)", chatID: 2, text: "Не сохранено"))
        XCTFail("fault expected")
      } catch let error as RepoError {
        XCTAssertEqual(error, fault == .storageFull ? .storageFull : .io)
      }
    }
    do {
      _ = try await h.repo.send(SendCommand(operationID: "one", chatID: 2, text: "Другой payload"))
      XCTFail("mismatch accepted")
    } catch let error as RepoError { XCTAssertEqual(error, .invalidInput) }
    let count = try await h.messageCount(chatID: 2)
    XCTAssertEqual(count, 1)
    let draft = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(draft.text, "Черновик 👨‍👩‍👧")
    let chats = try await h.repo.chats(matching: "")
    XCTAssertEqual(chats.first?.lastPreview, "Сохранено")
    try await h.close()
  }
  func testOpeningADamagedDatabaseReportsTheErrorAndPreservesItsBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try await RepositoryHarness.open(root: root)
    _ = try await saved.repo.send(SendCommand(
      operationID: "keep-previous-chat", chatID: 2, text: "Сохранённое сообщение"))
    try await saved.close()
    let database = root.appendingPathComponent("chat.sqlite3")
    let previous = try Data(contentsOf: database)
    var damaged = previous
    damaged.replaceSubrange(0..<16, with: repeatElement(UInt8(0x3f), count: 16))
    try damaged.write(to: database)

    do {
      let opened = try await SQLiteStore.open(root: root)
      try await opened.close()
      XCTFail("База с повреждённым заголовком открылась")
    } catch {
      XCTAssertEqual(error as? RepoError, .corrupt)
    }
    XCTAssertEqual(try Data(contentsOf: database), damaged)

    try previous.write(to: database)
    let restored = try await RepositoryHarness.open(root: root)
    let count = try await restored.messageCount(chatID: 2)
    XCTAssertEqual(count, 1)
    XCTAssertEqual(try restored.integrity(), "ok")
    try await restored.close()
  }

  func testFullDatabaseQueueRefusesOverflowAndThenAcceptsNewWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let h = try await RepositoryHarness.open(root: root)
    let entered = expectation(description: "Открытая работа удерживает очередь")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocking = Task {
      try await h.store.perform { _ in
        entered.fulfill()
        guard release.wait(timeout: .now() + 8) == .success else { throw RepoError.cancelled }
      }
    }
    await fulfillment(of: [entered], timeout: 3)

    let overflow = expectation(description: "Четыре команды сверх предела отклонены")
    overflow.expectedFulfillmentCount = 4
    let jobs = (0..<68).map { _ in
      Task {
        do {
          return Result<Int64, Error>.success(
            try await h.store.perform { db in try db.scalar("SELECT 1") })
        } catch {
          if error as? RepoError == .io { overflow.fulfill() }
          return .failure(error)
        }
      }
    }
    await fulfillment(of: [overflow], timeout: 4)
    release.signal()
    try await blocking.value
    var accepted = 0
    var rejected = 0
    for job in jobs {
      switch await job.value {
      case .success(let value):
        XCTAssertEqual(value, 1)
        accepted += 1
      case .failure(let error):
        XCTAssertEqual(error as? RepoError, .io)
        rejected += 1
      }
    }
    XCTAssertEqual(accepted, 64)
    XCTAssertEqual(rejected, 4)
    let count = try await h.messageCount(chatID: 2)
    XCTAssertEqual(count, 0)
    try await h.close()
  }

  // Закрывает и открывает базу с черновиком и точкой чтения, затем ищет буквальные знаки и
  // удаляет последнее сообщение. Проверяет, что подпись чата вернулась к предыдущей строке.
  func testDraftPositionDeleteAndLiteralSearch() async throws {
    var h = try await RepositoryHarness.open()
    let first = try await h.repo.send(
      SendCommand(operationID: "first", chatID: 2, text: "Поиск %_' 👋"))
    let id = try XCTUnwrap(first.inserted.first?.id)
    let anchor = ReadingAnchor(
      messageID: id, fraction: 0.4, textUTF16Offset: 3, screenDelta: 12, followsBottom: false,
      layoutVersion: 1)
    try await h.repo.savePosition(chatID: 2, anchor: anchor)
    try await h.repo.saveDraft(
      chatID: 2, draft: Draft(text: "Текст", replyToID: id, revision: 7, operationID: "pending"))
    h = try await h.reopen()
    let savedAnchor = try await h.repo.position(chatID: 2)
    XCTAssertEqual(savedAnchor, anchor)
    let draft = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(draft.replyToID, id)
    XCTAssertEqual(draft.operationID, "pending")
    let ids = try await h.repo.search(chatID: 2, text: "%_'", before: nil)
    XCTAssertEqual(ids, [id])
    _ = try await h.repo.send(SendCommand(operationID: "second", chatID: 2, text: "Последнее %_'"))
    let page = try await h.repo.history(PageRequest(chatID: 2))
    let last = try XCTUnwrap(page.rows.last)
    let allMatches = try await h.repo.search(chatID: 2, text: "%_'", before: nil)
    XCTAssertEqual(allMatches, [last.id, id])
    let olderMatches = try await h.repo.search(chatID: 2, text: "%_'", before: last.order)
    XCTAssertEqual(olderMatches, [id])
    _ = try await h.repo.delete(messageID: last.id)
    let remaining = try await h.repo.history(PageRequest(chatID: 2))
    XCTAssertEqual(remaining.rows.map(\.id), [id])
    let chats = try await h.repo.chats(matching: "")
    XCTAssertEqual(chats.first?.lastPreview, "Поиск %_' 👋")
    XCTAssertEqual(try h.integrity(), "ok")
    try await h.close()
  }
  // Открывает старую схему и проверяет новый номер, исходный текст, черновик и поиск по сообщению.
  // Иначе можно обновить таблицы, но потерять доступ к прежним данным.
  func testLegacyMigrationPreservesMessageAndDraft() async throws {
    let root = try RepositoryHarness.legacyRoot()
    let h = try await RepositoryHarness.open(root: root)
    XCTAssertEqual(try h.rawScalar("PRAGMA user_version"), 3)
    let page = try await h.repo.history(PageRequest(chatID: 2))
    XCTAssertEqual(page.rows.map(\.id), [7])
    XCTAssertEqual(page.rows.first?.text, "Ранее 👋")
    let draft = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(draft.text, "Старый черновик")
    let found = try await h.repo.search(chatID: 2, text: "ранее", before: nil)
    XCTAssertEqual(found, [7])
    XCTAssertEqual(try h.integrity(), "ok")
    try await h.close()
  }
  // Читает двести шестьдесят строк последовательными страницами и затем пишет старый черновик
  // после нового. Выявляет пропуски страниц и перезапись свежего ввода.
  func testKeysetPagesAndNewerDraftRevision() async throws {
    let h = try await RepositoryHarness.open()
    for i in 1...260 {
      _ = try await h.repo.send(
        SendCommand(operationID: "page-\(i)", chatID: 2, text: "Сообщение \(i)"))
    }
    let newest = try await h.repo.history(PageRequest(chatID: 2))
    XCTAssertEqual(newest.rows.map(\.id), Array(133...260).map(Int64.init))
    XCTAssertNil(newest.after)
    let middle = try await h.repo.history(
      PageRequest(chatID: 2, anchor: try XCTUnwrap(newest.before)))
    XCTAssertEqual(middle.rows.map(\.id), Array(5...132).map(Int64.init))
    let oldest = try await h.repo.history(
      PageRequest(chatID: 2, anchor: try XCTUnwrap(middle.before)))
    XCTAssertEqual(oldest.rows.map(\.id), [1, 2, 3, 4])
    XCTAssertNil(oldest.before)
    try await h.repo.saveDraft(chatID: 2, draft: Draft(text: "Новый", revision: 2))
    try await h.repo.saveDraft(chatID: 2, draft: Draft(text: "Запоздалый старый", revision: 1))
    let draft = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(draft.text, "Новый")
    try await h.close()
  }
  // Передаёт пустой текст и путь к файлу вне папки, проверяет отсутствие строк и незакрытых
  // запросов. После закрытия базы чтение должно завершиться отменой.
  func testInvalidInputAndNoLeakedStatements() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      try db.execute("INSERT INTO chats(id,title) VALUES(3,'Соседний чат')")
    }
    let neighbour = try await h.repo.send(
      SendCommand(operationID: "other-chat", chatID: 3, text: "Сообщение в другом чате"))
    let otherID = try XCTUnwrap(neighbour.inserted.first?.id)
    for command in [
      SendCommand(operationID: "blank", chatID: 2, text: " \n "),
      SendCommand(operationID: "cross-chat", chatID: 2, text: "Ответ", replyToID: otherID),
      SendCommand(
        operationID: "escape", chatID: 2, kind: .photo,
        attachments: [
          AttachmentDraft(id: "bad", relativePath: "../other.jpg", mime: "image/jpeg", byteSize: 1)
        ]),
      SendCommand(
        operationID: "missing-file", chatID: 2, kind: .photo,
        attachments: [
          AttachmentDraft(id: "missing", relativePath: "objects/missing.jpg", mime: "image/jpeg", byteSize: 1)
        ]),
    ] {
      do {
        _ = try await h.repo.send(command)
        XCTFail("invalid command accepted")
      } catch let error as RepoError { XCTAssertEqual(error, .invalidInput) }
    }
    let count = try await h.messageCount(chatID: 2)
    XCTAssertEqual(count, 0)
    let otherHistory = try await h.repo.history(PageRequest(chatID: 3))
    XCTAssertEqual(otherHistory.rows.map(\.id), [otherID])
    do {
      _ = try await h.repo.search(chatID: 4, text: "Сообщение", before: nil)
      XCTFail("Отсутствующий чат не должен принимать поиск")
    } catch RepoError.notFound {}
    let leaked = try await h.store.perform { db in sqlite3_next_stmt(db.handle, nil) != nil }
    XCTAssertFalse(leaked)
    try await h.close()
    do {
      _ = try await h.repo.chats(matching: "")
      XCTFail("closed store query accepted")
    } catch let error as RepoError { XCTAssertEqual(error, .cancelled) }
  }
}
