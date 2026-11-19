// Проверяем, когда поле ввода разрешает отправку. Нажимаем настоящую кнопку и сверяем, что после
// записи запроса в чате форма снова пуста.

import XCTest
import UIKit
@testable import Kandinsky
@MainActor final class ComposerAvailabilityTests: XCTestCase {
  func testHistoryReportsAReadFailureAndOpensAfterTheDatabaseRecovers() async throws {
    let harness = try await RepositoryHarness.open()
    let command = SendCommand(
      operationID: UUID().uuidString, chatID: 2, kind: .text,
      text: "Сообщение после восстановления истории", attachments: [])
    let sent = try await harness.repo.send(command)
    let message = try XCTUnwrap(sent.inserted.first)
    let frame = CGRect(x: 0, y: 0, width: 390, height: 690)
    let failing = ChatScrollHost()
    failing.frame = frame
    let failure = expectation(description: "История сообщила об ошибке чтения")
    failing.onError = { _ in failure.fulfill() }
    defer { failing.close() }

    try await harness.store.perform { db in
      _ = try db.execute("ALTER TABLE attachments RENAME TO unavailable_attachments")
    }
    try await failing.open(chatID: 2, repository: harness.repo, anchor: nil)
    let firstFrame = Task { try await failing.prepareInitialFrame() }
    await Task.yield()
    failing.requestPage(center: message.order)
    await fulfillment(of: [failure], timeout: 5)
    XCTAssertTrue(failing.loaded.isEmpty)
    failing.close()
    switch await firstFrame.result {
    case .success: XCTFail("Открытие истории завершилось несмотря на ошибку чтения")
    case .failure(let error): XCTAssertNotEqual(error as? RepoError, .cancelled)
    }
    try await harness.store.perform { db in
      _ = try db.execute("ALTER TABLE unavailable_attachments RENAME TO attachments")
    }
    let recovered = ChatScrollHost()
    recovered.frame = frame
    defer { recovered.close() }
    try await recovered.open(chatID: 2, repository: harness.repo, anchor: nil)
    try await recovered.prepareInitialFrame()
    XCTAssertEqual(recovered.loaded[message.id]?.text, command.text)
    XCTAssertEqual(try harness.integrity(), "ok")
    try await harness.close()
  }

  // Передаём полю пробелы, затем текст и нажимаем отправку. Без этой проверки кнопка могла бы
  // принять пустой запрос или остаться доступной после успешной очистки черновика.
  func testOnlySendableDraftEnablesNativeSendAndSuccessDisablesItAgain() async throws {
    let h = try await RepositoryHarness.open(), model = ConversationState(repository: h.repo)
    let view = ConversationChrome(chatID: 2, state: model, onBack: {})
    try await model.open(chatID: 2)
    try await view.openHistory(repository: h.repo, anchor: nil)
    let input = try XCTUnwrap(
      view.subviews.first { $0.accessibilityIdentifier == "composer.input" } as? UITextView)
    let send = try XCTUnwrap(
      view.subviews.first { $0.accessibilityIdentifier == "composer.send" } as? UIControl)
    XCTAssertFalse(send.isEnabled, "Empty local draft must not expose a send action")
    input.text = " \n "
    input.delegate?.textViewDidChange?(input)
    XCTAssertFalse(send.isEnabled)
    input.text = "готово"
    input.delegate?.textViewDidChange?(input)
    XCTAssertTrue(send.isEnabled)
    send.sendActions(for: .touchUpInside)
    let end = Date().addingTimeInterval(5)
    while !model.draft.text.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(model.draft.text.isEmpty)
    XCTAssertFalse(send.isEnabled)
    let count = try await h.messageCount(chatID: 2)
    XCTAssertEqual(count, 1)
    view.persistAnchorAndClose()
    await model.close()
    try await h.close()
  }
}
