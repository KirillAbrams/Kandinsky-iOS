// Проверяет выбор места после удаления и историю после копирования и удаления запроса. Тесты
// используют отдельные данные айфона.

import UIKit
import XCTest
@testable import Kandinsky

@MainActor final class MessageActionsTests: XCTestCase {
  func testActionSheetInvokesChosenCommandAfterDismissalAndEscapeDoesNotInvokeIt() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let host = UIViewController()
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      host.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }

    let invoked = expectation(description: "Команда вызвана после закрытия панели")
    var count = 0
    let action = KandinskySheetAction(title: "Убрать запрос", symbol: "trash", destructive: true) {
      XCTAssertNil(host.presentedViewController)
      count += 1
      invoked.fulfill()
    }
    let sheet = KandinskyActionSheet(title: "Запрос", items: [action])
    host.present(sheet, animated: false)
    sheet.view.layoutIfNeeded()
    XCTAssertTrue(sheet.view.accessibilityViewIsModal)
    let controls = descendants(in: sheet.view)
    XCTAssertTrue(controls.compactMap { ($0 as? UILabel)?.text }.contains("Запрос"))
    let buttons = controls.compactMap { $0 as? UIButton }
    let selected = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "actions.0" })
    let cancel = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "actions.1" })
    XCTAssertEqual(selected.configuration?.title, "Убрать запрос")
    XCTAssertEqual(selected.configuration?.baseForegroundColor, .systemRed)
    XCTAssertEqual(cancel.configuration?.title, "Отмена")
    XCTAssertGreaterThanOrEqual(selected.bounds.height, 48)
    selected.sendActions(for: .touchUpInside)
    await fulfillment(of: [invoked], timeout: 5)
    XCTAssertEqual(count, 1)

    let escaped = KandinskyActionSheet(items: [action])
    host.present(escaped, animated: false)
    XCTAssertTrue(escaped.accessibilityPerformEscape())
    for _ in 0..<100 where host.presentedViewController != nil {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertNil(host.presentedViewController)
    XCTAssertEqual(count, 1)
  }

  func testPendingPromptRequiresConfirmationAndStaleCopyShowsAnError() async throws {
    let h = try await RepositoryHarness.open()
    let repository = SQLiteChatRepository(store: h.store, journal: NetworkJournal(userID: 2))
    try await h.store.perform { try NetworkSchema.install($0) }
    let state = ConversationState(repository: repository)
    try await state.open(chatID: 2)
    let sent = try await repository.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, text: "Запрос ждёт отправки"))
    let row = try XCTUnwrap(sent.inserted.first)
    XCTAssertEqual(row.delivery, .pending)
    var draft = state.draft
    draft.text = "Другой запрос в черновике"
    state.editDraft(draft)
    try await state.flush()

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let parent = UIViewController()
    let window = UIWindow(windowScene: scene)
    window.rootViewController = parent
    window.makeKeyAndVisible()
    let actions = ConversationUIController(
      parent: parent.view, chatID: 2, repository: repository, state: state,
      onDelta: { _ in XCTFail("Одно открытие действия не должно менять историю") })
    defer {
      parent.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }

    actions.menu(message: row)
    let sheet = try XCTUnwrap(parent.presentedViewController as? KandinskyActionSheet)
    for _ in 0..<60 where sheet.isBeingPresented {
      try await Task.sleep(for: .milliseconds(20))
    }
    let buttons = descendants(in: sheet.view).compactMap { $0 as? UIButton }
    XCTAssertTrue(buttons.contains { $0.configuration?.title == "Копировать запрос" })
    let cancelSend = try XCTUnwrap(buttons.first { $0.configuration?.title == "Отменить отправку" })
    cancelSend.sendActions(for: .touchUpInside)
    let asksFirst = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (parent.presentedViewController as? UIAlertController)?.title == "Отменить отправку?"
    }, object: nil)
    await fulfillment(of: [asksFirst], timeout: 5)
    let confirmation = try XCTUnwrap(parent.presentedViewController as? UIAlertController)
    XCTAssertEqual(confirmation.actions.map(\.title), ["Оставить", "Отменить отправку"])
    XCTAssertEqual(confirmation.actions.map(\.style), [.cancel, .destructive])
    let before = try await repository.history(PageRequest(chatID: 2))
    XCTAssertEqual(before.rows.map(\.id), [row.id])
    await withCheckedContinuation { continuation in
      parent.dismiss(animated: false) { continuation.resume() }
    }

    _ = try await repository.delete(messageID: row.id)
    actions.perform(.copy, message: row)
    let failure = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (parent.presentedViewController as? UIAlertController)?.title == "Действие не выполнено"
    }, object: nil)
    await fulfillment(of: [failure], timeout: 5)
    let after = try await repository.draft(chatID: 2)
    XCTAssertEqual(after.text, draft.text)
    await state.close()
    try await h.close()
  }

  func testGenerationActionsBlockOnlyTheRowWaitingForAResponse() async throws {
    let harness = try await RepositoryHarness.open()
    let state = ConversationState(repository: harness.repo)
    let parent = UIView()
    let controller = ConversationUIController(
      parent: parent, chatID: 2, repository: harness.repo, state: state,
      onDelta: { _ in XCTFail("Действие не должно переписывать местную историю") })
    let delayed = AsyncStream<Void>.makeStream()
    defer { delayed.continuation.finish() }
    let started = expectation(description: "Отправлена только одна отмена")
    let rejected = expectation(description: "Получен отказ отмены")
    let otherDeleted = expectation(description: "Соседний результат обработан")
    let originalDeleted = expectation(description: "Запрос по прежней строке разрешён после отказа")
    started.assertForOverFulfill = true
    originalDeleted.assertForOverFulfill = true
    var mayActOnOriginal = false
    let blob = String(repeating: "a", count: 32)

    controller.generationAction = { id, action, operation in
      XCTAssertEqual(id, 17)
      XCTAssertEqual(action, .cancel)
      XCTAssertNil(operation)
      started.fulfill()
      for await _ in delayed.stream {}
      rejected.fulfill()
      throw RepoError.io
    }
    controller.deleteGenerationContent = { id, target in
      XCTAssertEqual(target, blob)
      if id == 18 {
        otherDeleted.fulfill()
      } else {
        XCTAssertEqual(id, 17)
        XCTAssertTrue(mayActOnOriginal)
        originalDeleted.fulfill()
      }
    }

    controller.performGenerationAction(17, action: .cancel)
    await fulfillment(of: [started], timeout: 3)
    controller.performGenerationAction(17, action: .cancel)
    controller.removeGenerationContent(17, blob: blob)
    controller.removeGenerationContent(18, blob: blob)
    await fulfillment(of: [otherDeleted], timeout: 3)
    delayed.continuation.finish()
    await fulfillment(of: [rejected], timeout: 3)
    mayActOnOriginal = true
    controller.removeGenerationContent(17, blob: blob)
    await fulfillment(of: [originalDeleted], timeout: 3)
    await state.close()
    try await harness.close()
  }

  func testSlotRetryUsesTheSameOperationForTheSameRunAfterAnError() async throws {
    let harness = try await RepositoryHarness.open()
    let state = ConversationState(repository: harness.repo)
    let parent = UIView()
    let controller = ConversationUIController(
      parent: parent, chatID: 2, repository: harness.repo, state: state, onDelta: { _ in })
    let slot = StudioGeneration.Slot(
      id: UUID().uuidString, status: .failed, blobId: nil, progress: nil, runId: UUID().uuidString)
    let blockedSlot = StudioGeneration.Slot(
      id: UUID().uuidString, status: .failed, blobId: nil, progress: nil, moderated: true)
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let started = expectation(description: "Ожидается ответ первой попытки")
    let failed = expectation(description: "Первая попытка завершилась")
    let repeated = expectation(description: "Повтор передал тот же номер")
    var operations: [UUID] = []
    controller.retrySlotAction = { message, selected, operation in
      XCTAssertEqual(message, 91)
      XCTAssertEqual(selected, slot)
      operations.append(operation)
      switch operations.count {
      case 1:
        started.fulfill()
        for await _ in gate.stream {}
        failed.fulfill()
        throw RepoError.io
      case 2:
        XCTAssertEqual(operations[0], operation)
        repeated.fulfill()
      default:
        XCTFail("Отправлен лишний повтор")
      }
    }
    controller.retrySlot(91, slot: slot)
    controller.retrySlot(91, slot: blockedSlot)
    await fulfillment(of: [started], timeout: 3)
    controller.retrySlot(91, slot: slot)
    gate.continuation.finish()
    await fulfillment(of: [failed], timeout: 3)
    XCTAssertEqual(operations.count, 1)
    controller.retrySlot(91, slot: slot)
    await fulfillment(of: [repeated], timeout: 3)
    XCTAssertEqual(operations.count, 2)
    await state.close()
    try await harness.close()
  }

  func testARejectedReportCanBeRetriedWithAnotherReason() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let host = UIViewController()
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      host.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }

    let harness = try await RepositoryHarness.open()
    let state = ConversationState(repository: harness.repo)
    let controller = ConversationUIController(
      parent: host.view, chatID: 2, repository: harness.repo, state: state,
      onDelta: { _ in XCTFail("Жалоба не меняет сохранённое сообщение") })
    let photo = Attachment(
      id: "result", relativePath: "result.jpg", mime: "image/jpeg", byteSize: 300,
      rawWidth: 10, rawHeight: 10, orientation: 1, durationMs: nil, thumbnailKey: "")
    let message = Message(
      id: 17, chatID: 2, order: OrderKey(sortKey: 17, messageID: 17),
      direction: .incoming, savedAtMs: 0, kind: .photo, text: "", caption: "",
      replyToID: nil, revision: 1, attachments: [photo])
    let sent = expectation(description: "Отправлена одна жалоба")
    sent.assertForOverFulfill = true
    let waiting = AsyncStream<Void>.makeStream()
    defer { waiting.continuation.finish() }
    let laterReply = AsyncStream<Void>.makeStream()
    defer { laterReply.continuation.finish() }
    let startedLastReport = expectation(description: "Третья жалоба ждёт ответ")
    let lastReportReturned = expectation(description: "Ответ получен поверх другого окна")
    var reports: [StudioReportReason] = []
    controller.reportGeneration = { id, reason in
      XCTAssertEqual(id, message.id)
      reports.append(reason)
      if reports.count == 1 {
        sent.fulfill()
        for await _ in waiting.stream {}
        throw RepoError.io
      }
      if reports.count == 3 {
        startedLastReport.fulfill()
        for await _ in laterReply.stream {}
        lastReportReturned.fulfill()
      }
    }

    func choose(_ reason: StudioReportReason) throws {
      controller.menu(message: message)
      let sheet = try XCTUnwrap(host.presentedViewController as? KandinskyActionSheet)
      let buttons = descendants(in: sheet.view).compactMap { $0 as? UIButton }
      let action = try XCTUnwrap(buttons.first { $0.configuration?.title == reason.title })
      action.sendActions(for: .touchUpInside)
    }

    func alert(_ title: String) async throws -> UIAlertController {
      for _ in 0..<100 {
        if let prompt = host.presentedViewController as? UIAlertController, prompt.title == title {
          return prompt
        }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      XCTFail("Подтверждение жалобы не появилось. Ожидали заголовок \(title)")
      throw RepoError.io
    }

    try choose(.harmful)
    await fulfillment(of: [sent], timeout: 5)
    controller.menu(message: message)
    XCTAssertNil(host.presentedViewController)
    waiting.continuation.finish()
    let rejection = try await alert("Жалобу не удалось отправить")
    XCTAssertEqual(rejection.message, "Попробуйте ещё раз.")
    await withCheckedContinuation { continuation in
      rejection.dismiss(animated: false) { continuation.resume() }
    }

    try choose(.other)
    let confirmation = try await alert("Жалоба отправлена")
    XCTAssertNil(confirmation.message)
    XCTAssertEqual(reports, [.harmful, .other])
    await withCheckedContinuation { continuation in
      confirmation.dismiss(animated: false) { continuation.resume() }
    }
    try choose(.inappropriate)
    await fulfillment(of: [startedLastReport], timeout: 3)
    let nextScreen = UIViewController()
    host.present(nextScreen, animated: false)
    laterReply.continuation.finish()
    await fulfillment(of: [lastReportReturned], timeout: 3)
    XCTAssertTrue(host.presentedViewController === nextScreen)
    XCTAssertNil(nextScreen.presentedViewController)
    XCTAssertEqual(reports, [.harmful, .other, .inappropriate])
    await state.close()
    try await harness.close()
  }

  private func descendants(in view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants(in: $0) }
  }

  // Удаляет строки с обеих сторон текущего места и сверяет выбор следующей либо предыдущей.
  // Сохранённая строка не должна терять своё смещение.
  func testDeletedReadingAnchorChoosesNeighbor() {
    let rows = (1...3).map { n in
      IndexedRow(
        messageID: Int64(n), order: OrderKey(sortKey: Int64(n), messageID: Int64(n)),
        estimatedHeight: 44, revision: 1)
    }
    let anchor = ReadingAnchor(
      messageID: 2, fraction: 0.4, textUTF16Offset: 17, screenDelta: -4, followsBottom: false)
    let next = ReadingAnchorResolver.afterRemoving(anchor, rows: rows, removed: [1, 2])
    XCTAssertEqual(next.messageID, 3)
    XCTAssertEqual(next.fraction, 0)
    XCTAssertNil(next.textUTF16Offset)
    let previous = ReadingAnchorResolver.afterRemoving(anchor, rows: rows, removed: [2, 3])
    XCTAssertEqual(previous.messageID, 1)
    XCTAssertEqual(ReadingAnchorResolver.afterRemoving(anchor, rows: rows, removed: [1]), anchor)
  }

  // Копирует текст с разными знаками и удаляет исходную строку после отправки следующей. Черновик
  // теряет только ссылку, а новая история сохраняется после открытия базы.
  func testPromptCopyAndRemovalPreserveDraftAndFollowingHistory() async throws {
    var harness = try await RepositoryHarness.open()
    let source = "Поиск 👨‍👩‍👧‍👦 é العربية"
    let id = try await harness.repo.send(
      SendCommand(operationID: "source", chatID: 2, text: source)
    ).inserted[0].id
    let state = ConversationState(repository: harness.repo)
    try await state.open(chatID: 2)
    var copied = ""
    let actions = MessageActions(
      chatID: 2, repository: harness.repo, state: state, copyText: { copied = $0 })
    let copiedText = try await actions.copy(id: id)
    XCTAssertEqual(copiedText, source)
    XCTAssertEqual(copied, source)
    var next = state.draft
    next.text = "Следующий запрос"
    state.editDraft(next)
    await state.send()
    var saved = state.draft
    saved.replyToID = id
    state.editDraft(saved)
    try await state.flush()
    _ = try await actions.delete(id: id)
    XCTAssertNil(state.draft.replyToID)
    let page = try await harness.repo.history(PageRequest(chatID: 2))
    XCTAssertEqual(page.rows.count, 1)
    XCTAssertEqual(page.rows.first?.text, "Следующий запрос")
    await state.close()
    harness = try await harness.reopen()
    let reopenedPage = try await harness.repo.history(PageRequest(chatID: 2))
    XCTAssertEqual(reopenedPage.rows.first?.text, "Следующий запрос")
    XCTAssertEqual(try harness.integrity(), "ok")
    try await harness.close()
  }

  func testRefusedDeletionKeepsTheMessageAndItsQueuedSendUntilRetry() async throws {
    let harness = try await RepositoryHarness.open()
    try await harness.store.perform { try NetworkSchema.install($0) }
    let repository = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: 2))
    let state = ConversationState(repository: repository)
    let delta = try await repository.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, text: "Запрос ещё ждёт отправки"))
    let original = try XCTUnwrap(delta.inserted.first)
    let actions = MessageActions(chatID: 2, repository: repository, state: state) { _ in
      XCTFail("Удаление не должно обращаться к буферу обмена")
    }
    var removed: [Int64] = []
    actions.onDelta = { removed.append(contentsOf: $0.removedIDs) }
    try await harness.store.perform { db in
      try db.execute("""
        CREATE TRIGGER coverage_refused_deletion BEFORE DELETE ON messages
        BEGIN SELECT RAISE(ABORT,'write refused'); END
        """)
    }

    do {
      _ = try await actions.delete(id: original.id)
      XCTFail("При отказе базы удаление должно завершиться ошибкой")
    } catch {
      XCTAssertTrue(removed.isEmpty)
    }
    let retained = try await repository.history(PageRequest(chatID: 2))
    XCTAssertEqual(retained.rows.map(\.id), [original.id])
    XCTAssertEqual(retained.rows.first?.delivery, .pending)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE action='send'"), 1)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE action='delete'"), 0)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_messages WHERE tombstone=1"), 0)

    try await harness.store.perform { try $0.execute("DROP TRIGGER coverage_refused_deletion") }
    _ = try await actions.delete(id: original.id)
    XCTAssertEqual(removed, [original.id])
    let after = try await repository.history(PageRequest(chatID: 2))
    XCTAssertTrue(after.rows.isEmpty)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE action='delete'"), 1)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_messages WHERE tombstone=1"), 1)
    XCTAssertEqual(try harness.integrity(), "ok")
    await state.close()
    try await harness.close()
  }
}
