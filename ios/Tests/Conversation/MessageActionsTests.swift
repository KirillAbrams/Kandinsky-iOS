import XCTest
@testable import Kandinsky

@MainActor final class MessageActionsTests: XCTestCase {
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
}
